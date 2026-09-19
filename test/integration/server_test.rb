# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"
require "socket"

class ServerTest < Minitest::Test
  def test_literal_creation_topology_and_terminal_input
    LibTmuxTest::TmuxFixture.open do |fixture|
      executable = File.join(File.dirname(fixture.socket_path), "literal ; executable")
      File.write(executable, "#!/bin/sh\nexec /bin/cat\n")
      File.chmod(0o700, executable)
      open_server(fixture) do |server|
        name = "session \#{pid} ';"
        session = server.new_session(name: name, command: [executable], width: 80, height: 24)
        assert_match(/\A\$\d+\z/, session.id)
        assert_equal "#{name}\n", server.run(["display-message", "-p", "-t", session.id, '#{session_name}']).text
        assert_equal ["$0", session.id], server.list_sessions.map(&:id)

        receipt = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "receipt"))
        begin
          code = 'line = STDIN.gets; UNIXSocket.open(ARGV.fetch(0)) { |io| io.write(line) }; STDIN.read'
          window = session.new_window(name: "window \#{pane_id};", command: [Gem.ruby, "--disable=rubyopt,gems", "-rsocket", "-e", code, receipt.path])
          assert_match(/\A@\d+\z/, window.id)
          assert_equal "window \#{pane_id};\n", server.run(["display-message", "-p", "-t", window.id, '#{window_name}']).text
          pane = window.list_panes.fetch(0)
          text = "C-a \#{pane_id};"
          assert pane.send_text(text).success?
          assert pane.send_keys("Enter").success?
          assert IO.select([receipt], nil, nil, 0.5), "pane did not acknowledge literal input"
          client = receipt.accept
          begin
            assert IO.select([client], nil, nil, 0.5), "pane input receipt was empty"
            assert_equal "#{text}\n", client.read
          ensure
            client.close
          end
          capture = pane.capture
          assert_equal "#{text}\n", capture.text.lines.first
          assert_equal Encoding::BINARY, capture.stdout.encoding
          assert capture.stdout.end_with?("\n")

          split = window.split(direction: :horizontal, command: ["/bin/cat"])
          refute_equal pane.id, split.id
          assert_equal [pane.id, split.id], window.list_panes.map(&:id)
          assert window.select_layout(:tiled).success?
          split.kill
          assert_raises(LibTmux::CommandError) { split.kill }
          assert_equal [pane.id], window.list_panes.map(&:id)
          window.kill
          session.kill
          assert_equal ["$0"], server.list_sessions.map(&:id)
        ensure
          receipt.close
        end
      end
    end
  end

  def test_refs_are_binding_scoped_and_readers_remain_local_after_close
    LibTmuxTest::TmuxFixture.open do |first|
      LibTmuxTest::TmuxFixture.open do |second|
        open_server(first) do |left|
          open_server(second) do |right|
            a = left.list_panes.fetch(0)
            b = right.list_panes.fetch(0)
            assert_equal a.id, b.id
            refute_equal a.ref, b.ref
            assert_raises(LibTmux::TargetNotFoundError) { right.pane(a.ref) }
            assert_equal a, left.pane(a.ref)
            assert a.frozen?
            assert a.ref.frozen?
            assert a.ref.id.frozen?
            assert_raises(ArgumentError) { left.run(["-S", second.socket_path, "kill-server"]) }
            left.close
            assert_equal "%0", a.id
            assert_equal :pane, a.ref.kind
            assert_raises(LibTmux::ClosedError) { a.capture }
            assert first.tmux("has-session", "-t", "fixture").last.success?
            open_server(first) do |reopened|
              assert_raises(LibTmux::TargetNotFoundError) { reopened.pane(a.ref) }
            end
          end
        end
      end
    end
  end

  def test_dead_original_handles_cannot_dispatch_to_replaced_selector
    LibTmuxTest::TmuxFixture.open do |replacement|
      server = nil
      original_path = nil
      LibTmuxTest::TmuxFixture.open do |original|
        original_path = original.socket_path
        server = open_server(original)
      end
      begin
        Dir.mkdir(File.dirname(original_path), 0o700)
        File.link(replacement.socket_path, original_path)
        failure = assert_raises(LibTmux::CommandError) do
          server.new_session(name: "must-not-exist", command: ["/bin/cat"])
        end
        refute failure.result.success?
        assert_equal :observed, failure.delivery
        refute replacement.tmux("has-session", "-t", "must-not-exist").last.success?
      ensure
        server&.close
        File.unlink(original_path) if File.socket?(original_path)
        Dir.rmdir(File.dirname(original_path)) if Dir.exist?(File.dirname(original_path))
      end
    end
  end

  def test_close_cancels_owned_clients_and_preserves_the_borrowed_daemon
    LibTmuxTest::TmuxFixture.open do |fixture|
      server = open_server(fixture)
      request = Thread.new do
        server.run(["wait-for", "-S", "ruby-ready", ";", "wait-for", "ruby-held"])
      rescue LibTmux::Cancelled => error
        error
      end
      begin
        assert fixture.tmux("wait-for", "ruby-ready").last.success?
        server.close
        assert request.join(0.5), "server close did not retire its client"
        assert_instance_of LibTmux::Cancelled, request.value
        assert fixture.tmux("has-session", "-t", "fixture").last.success?
      ensure
        server.close
        request.join(0.5)
      end
    end
  end

  def test_block_result_and_original_exception_survive_cleanup
    LibTmuxTest::TmuxFixture.open do |fixture|
      assert_equal :value, open_server(fixture) { :value }
      original = RuntimeError.new("caller failure")
      observed = assert_raises(RuntimeError) { open_server(fixture) { raise original } }
      assert_same original, observed
      assert fixture.tmux("has-session", "-t", "fixture").last.success?
    end
  end

  def test_pre_cancelled_request_never_attempts_spawn
    LibTmuxTest::TmuxFixture.open do |fixture|
      executable = File.join(File.dirname(fixture.socket_path), "removed-client")
      File.write(executable, "#!/bin/sh\nexit 1\n")
      File.chmod(0o700, executable)
      endpoint = LibTmux::Endpoint.new(socket_path: fixture.socket_path, executable: executable)
      LibTmux::Server.open(endpoint: endpoint) do |server|
        File.unlink(executable)
        token = LibTmux::Internal::Cancellation.new
        begin
          token.cancel
          failure = assert_raises(LibTmux::Cancelled) { server.run(["list-sessions"], cancel: token) }
          assert_equal :not_sent, failure.delivery
        ensure
          token.close
        end
      end
    end
  end

  def test_admission_is_bounded_and_close_can_retry_after_its_deadline
    LibTmuxTest::TmuxFixture.open do |fixture|
      server = LibTmux::Server.open(socket_path: fixture.socket_path, max_requests: 2, close_timeout: Float::MIN)
      requests = []
      begin
        2.times do |index|
          requests << Thread.new do
            server.run(["wait-for", "-S", "ready-#{index}", ";", "wait-for", "held-#{index}"])
          rescue LibTmux::Cancelled => error
            error
          end
          assert fixture.tmux("wait-for", "ready-#{index}").last.success?
        end
        failure = assert_raises(LibTmux::CapacityError) { server.run(["list-sessions"]) }
        assert_equal :not_sent, failure.delivery
        failure = assert_raises(LibTmux::DeadlineExceeded) { server.close }
        assert_equal :retire, failure.phase
        requests.each { |request| assert request.join(0.5), "cancelled client did not retire" }
        server.close
        assert fixture.tmux("has-session", "-t", "fixture").last.success?
      ensure
        requests.each { |request| request.join(0.5) }
        server.close
      end
    end
  end

  def test_repeated_interrupt_preserves_the_block_error_during_close
    LibTmuxTest::TmuxFixture.open do |fixture|
      entered = Queue.new
      release = Queue.new
      type = Class.new(LibTmux::Server) do
        define_method(:close) do
          super()
          entered << true
          release.pop
        end
      end
      original = RuntimeError.new("first failure")
      deferred = RuntimeError.new("second failure")
      worker = Thread.new do
        type.open(socket_path: fixture.socket_path) { raise original }
      rescue Exception => failure
        failure
      end
      begin
        entered.pop
        worker.raise(deferred)
        release << true
        assert worker.join(0.5), "cleanup did not finish"
        assert_same original, worker.value
      ensure
        release << true
        worker.join(0.5)
      end
    end
  end

  def test_fork_close_cannot_cancel_a_parent_request
    LibTmuxTest::TmuxFixture.open do |fixture|
      server = open_server(fixture)
      request = Thread.new do
        server.run(["wait-for", "-S", "fork-ready", ";", "wait-for", "fork-held"])
      rescue LibTmux::Cancelled => failure
        failure
      end
      reader, writer = IO.pipe
      child = nil
      begin
        assert fixture.tmux("wait-for", "fork-ready").last.success?
        child = fork do
          reader.close
          server.close
          begin
            server.run(["list-sessions"])
            exit! 1
          rescue LibTmux::ClosedError
            writer.write("closed")
            exit! 0
          end
        end
        writer.close
        assert IO.select([reader], nil, nil, 0.5), "fork close blocked on parent requests"
        assert_equal "closed", reader.read
        _, status = Process.wait2(child)
        child = nil
        assert status.success?
        assert fixture.tmux("wait-for", "-S", "fork-held").last.success?
        assert request.join(0.5), "parent request did not finish"
        assert_instance_of LibTmux::CommandResult, request.value
        assert request.value.success?
      ensure
        if child
          Process.kill("KILL", child)
          Process.wait2(child)
        end
        reader.close
        writer.close unless writer.closed?
        server.close
        request.join(0.5)
      end
    end
  end

  private

  def open_server(fixture, &block)
    assert defined?(LibTmux::Server), "Server API is not implemented"
    LibTmux::Server.open(socket_path: fixture.socket_path, &block)
  end
end
