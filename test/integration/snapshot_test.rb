# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"
require "libtmux/control"
require "socket"
require "libtmux/capture" if File.exist?(File.expand_path("../../gems/libtmux/lib/libtmux/capture.rb", __dir__))

class SnapshotIntegrationTest < Minitest::Test
  def test_three_links_have_one_global_window_and_local_readers_outlive_server
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        assert server.run(["link-window", "-s", "@0", "-t", "$0:5"]).success?
        assert server.run(["link-window", "-s", "@0", "-t", "$0:10"]).success?
        capture = acquire(server, clients: true)
        assert_equal ["@0"], capture.windows.map(&:id)
        assert_equal ["%0"], capture.panes.map(&:id)
        assert_equal [0, 5, 10], capture.window_links.map(&:index)
        assert_equal ["@0", "@0", "@0"], capture.sessions.one.windows.map(&:id)
        assert_equal 3, capture.window_links.map(&:ref).uniq.size
        assert_equal capture.window_links.first.ref, server.list_window_links.first.ref
        assert_empty capture.clients
        assert capture.finished_at >= capture.started_at
        assert_operator capture.server_info.fetch(:pid), :>, 0
        assert capture.server_info.fetch(:version).frozen?
        assert_equal %i[server session window_link pane client], capture.reads.map { |read| read.fetch(:source) }
        refreshed = acquire(server)
        assert_equal capture.panes.one.ref, refreshed.panes.one.ref
        refute_equal capture.panes.one, refreshed.panes.one
        server.close
        assert_equal ["@0", "@0", "@0"], capture.sessions.one.windows.map(&:id)
        assert_equal ["%0"], capture.panes.one.window.panes.map(&:id)
        assert capture.panes.one.active?
        refute_empty capture.panes.one.current_command
      end
    end
  end

  def test_embedded_newlines_and_invalid_utf8_are_preserved_in_metadata
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        directory = File.join(File.dirname(fixture.socket_path).b, "line\n: café\xFF".b)
        Dir.mkdir(directory)
        ready = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "ready"))
        begin
          code = 'UNIXSocket.open(ARGV.fetch(0)) { |io| io.write("ready") }; STDIN.read'
          assert server.run(["new-window", "-d", "-t", "$0", "-c", directory, "--",
            Gem.ruby, "--disable=rubyopt,gems", "-rsocket", "-e", code, ready.path]).success?
          assert IO.select([ready], nil, nil, 0.5), "pane did not announce its working directory"
          peer = ready.accept
          begin
            assert IO.select([peer], nil, nil, 0.5), "pane readiness data did not arrive"
            assert_equal "ready", peer.read
          ensure
            peer.close
          end
          capture = acquire(server)
          pane = capture.panes.select { |record| record.id == "%1" }.one
          assert_equal directory, pane.raw(:current_path)
          assert_equal 0, pane.index
          assert_raises(LibTmux::FieldDecodeError) { pane.current_path }
          assert_raises(LibTmux::IncompleteSnapshotError) { capture.clients }
        ensure
          ready.close
        end
      end
    end
  end

  def test_a_real_capture_race_retries_once_and_persistent_races_raise
    LibTmuxTest::TmuxFixture.open do |fixture|
      racing_server = Class.new(LibTmux::Server) do
        attr_accessor :race_limit
        attr_reader :race_count

        private

        def execute_typed(argv, **options)
          result = super
          if argv.first == "list-windows" && (@race_count || 0) < race_limit
            @race_count = (@race_count || 0) + 1
            super(["new-window", "-d", "-t", "$0", "--", "/bin/cat"], **options)
          end
          result
        end
      end
      racing_server.open(socket_path: fixture.socket_path) do |server|
        server.race_limit = 1
        capture = acquire(server)
        assert_equal 2, capture.windows.size
        assert_equal 1, server.race_count
        assert_equal [1, 2], capture.reads.map { |read| read.fetch(:attempt) }.uniq
      end
      racing_server.open(socket_path: fixture.socket_path) do |server|
        server.race_limit = 10
        assert_raises(LibTmux::InconsistentSnapshotError) { acquire(server) }
        assert_equal 2, server.race_count
      end
    end
  end

  def test_capture_bounds_are_checked_without_mutation
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        assert_raises(LibTmux::CapacityError) { acquire(server, max_bytes: 8) }
        assert_raises(LibTmux::CapacityError) { acquire(server, max_rows: 1) }
        assert_raises(LibTmux::DeadlineExceeded) { acquire(server, timeout: 0) }
        token = LibTmux::Internal::Cancellation.new
        begin
          token.cancel
          error = assert_raises(LibTmux::Cancelled) { acquire(server, cancel: token) }
          assert_equal :not_sent, error.delivery
        ensure
          token.close
        end
        assert_equal ["$0"], server.list_sessions.map(&:id)
      end
    end
  end

  def test_requested_clients_are_observations_and_empty_server_is_a_complete_graph
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        pin = LibTmux::Internal::SocketIdentity.new(server.endpoint)
        begin
          LibTmux::ControlConnection.open(binding: pin, session_id: "$0") do |control|
            control.exchange("display-message -p ready", timeout: 0.5)
            capture = acquire(server, clients: true)
            client = capture.clients.one
            assert_equal control.pid, client.pid
            assert_equal "$0", client.session_id
            assert client.control_mode?
            assert client.utf8?
            assert_nil client.height
            assert_same capture.sessions.one, client.session
            assert client.name.frozen?
            assert_raises(LibTmux::UnsupportedFeatureError) { client.ref }
          end
        ensure
          pin.close
        end
        assert server.run(["set-option", "-s", "exit-empty", "off"]).success?
        assert server.run(["kill-session", "-t", "$0"]).success?
        capture = acquire(server, clients: true)
        assert_empty capture.sessions
        assert_empty capture.windows
        assert_empty capture.panes
        assert_empty capture.window_links
        assert_empty capture.clients
      end
    end
  end

  private

  def acquire(server, **options)
    server.snapshot(**options)
  end
end
