# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux/workspace"
require "socket"
require "shellwords"

class WorkspaceApplyTest < Minitest::Test
  def test_history_limit_precedes_new_panes_and_preserves_native_initial_grid
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        inherited = server.options(scope: :session).get("history-limit").as(:integer)
        source = {"session_name" => "history", "options" => {"history-limit" => 123}, "windows" => [
          {"window_name" => "first", "panes" => [{}, {}]},
          {"window_name" => "second", "panes" => [{}]}
        ]}
        result = workspace(source, File.dirname(fixture.socket_path)).plan.apply(server: server)
        assert result.success?
        limits = %w[pane:0:0 pane:0:1 pane:1:0].map do |key|
          server.pane(result.created_refs.fetch(key)).display('#{history_limit}').text.to_i
        end
        assert_equal [123, 123], limits.drop(1)
        release = Gem::Version.new(server.snapshot.server_info.fetch(:version)[/\d+\.\d+/])
        assert_equal release >= Gem::Version.new("3.7") ? 123 : inherited, limits.first
        assert_equal inherited, server.options(scope: :session).get("history-limit").as(:integer)
      end
    end
  end

  def test_apply_reuses_initial_entities_and_reports_dispatch_without_shell_completion
    LibTmuxTest::TmuxFixture.open do |fixture|
      directory = File.dirname(fixture.socket_path)
      listener = UNIXServer.new(File.join(directory, "workspace-receipt"))
      begin
        LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
          server.options(scope: :window).set("synchronize-panes", true)
          source = {"session_name" => "workspace", "environment" => {"ROOT" => "root"}, "windows" => [
            {"window_name" => "first", "window_index" => 3, "layout" => "tiled", "panes" => [
              {"environment" => {"ROOT" => "pane"}, "shell_command" => receipt_command(listener.path)}, {}]},
            {"window_name" => "second", "window_index" => 7, "focus" => true, "panes" => [{}]}
          ]}
          plan = workspace(source, directory).plan(snapshot: server.snapshot)
          result = plan.apply(server: server)
          assert result.success?
          assert_equal plan.steps.map(&:id), result.completed_steps
          assert_equal 6, result.created_refs.length
          session = server.session(result.created_refs.fetch("session"))
          assert_equal [3, 7], session.list_window_links.map(&:index)
          assert_equal 3, session.list_panes.length
          assert_equal "root", session.environment("ROOT")
          assert_equal "#{result.created_refs.fetch('window:1').id}\n", session.display('#{window_id}').text
          assert IO.select([listener], nil, nil, 0.5), "authored shell command did not send its receipt"
          client = listener.accept
          begin
            assert_equal [File.realpath(directory), "pane"], Marshal.load(client.read)
          ensure
            client.close
          end
          assert_equal 1, result.effects.count { |effect| effect.action == :dispatch_command }
          assert_equal :dispatch_only, result.effects.find { |effect| effect.action == :dispatch_command }.outcome
          assert result.created_refs.frozen?
          refute_includes result.inspect, directory
          conflict = assert_raises(LibTmux::Workspace::ApplyError) { plan.apply(server: server) }
          assert_empty conflict.result.created_refs
          assert_equal "LibTmux::Workspace::ConflictError", conflict.failure_class
          assert_equal 2, server.list_sessions.length
        end
      ensure
        listener.close
      end
    end
  end

  def test_initial_children_replaced_after_creation_are_never_attributed_as_created
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        source = {"session_name" => "partial", "windows" => [{"window_name" => "one", "panes" => [{}]}]}
        plan = workspace(source, File.dirname(fixture.socket_path)).plan
        borrowed = server.list_window_links.fetch(0)
        original = server.method(:new_session)
        server.define_singleton_method(:new_session) do |**options|
          receipt = original.call(**options)
          borrowed.move(session: receipt.entity.ref, index: 9)
          receipt.window.kill
          receipt
        end
        error = assert_raises(LibTmux::Workspace::ApplyError) { plan.apply(server: server, compensate: true) }
        assert_equal 3, error.result.created_refs.length
        refute_includes error.result.created_refs.values.map(&:id), borrowed.id
        assert_equal :failed, error.result.compensation
        assert_equal [borrowed.id], server.list_windows.map(&:id)
      end
    end
  end

  def test_precancelled_apply_and_foreign_snapshot_refuse_before_creation
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        source = {"session_name" => "refused", "windows" => [{"window_name" => "one", "panes" => [{}]}]}
        config = workspace(source, File.dirname(fixture.socket_path))
        cancellation = LibTmux::Internal::Cancellation.new
        begin
          cancellation.cancel
          error = assert_raises(LibTmux::Workspace::ApplyError) { config.plan.apply(server: server, cancel: cancellation) }
          assert_empty error.result.created_refs
          assert_equal :not_sent, error.delivery
        ensure
          cancellation.close
        end
        LibTmux::Server.open(socket_path: fixture.socket_path) do |other_binding|
          plan = config.plan(snapshot: other_binding.snapshot)
          error = assert_raises(LibTmux::Workspace::ApplyError) { plan.apply(server: server) }
          assert_equal "LibTmux::Workspace::ConflictError", error.failure_class
          assert_empty error.result.effects
        end
        assert_equal 1, server.list_sessions.length
      end
    end
  end

  def test_lost_creation_reply_remains_uncertain_and_never_compensates_by_name
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        source = {"session_name" => "unconfirmed", "windows" => [{"window_name" => "one", "panes" => [{}]}]}
        create = server.method(:new_session)
        server.define_singleton_method(:new_session) do |**options|
          create.call(**options)
          raise LibTmux::TransportError.new("private-lost-reply", delivery: :possibly_sent)
        end
        error = assert_raises(LibTmux::Workspace::ApplyError) do
          workspace(source, File.dirname(fixture.socket_path)).plan.apply(server: server, compensate: true)
        end
        assert error.result.uncertain?
        assert_equal :possibly_sent, error.delivery
        assert_equal :nothing_owned, error.result.compensation
        assert_empty error.result.created_refs
        assert_equal ["fixture", "unconfirmed"], server.snapshot.sessions.map(&:name).sort
        refute_includes error.full_message, "private-lost-reply"
      end
    end
  end

  def test_pending_interrupt_records_creation_before_compensation_and_keeps_primary_failure
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        source = {"session_name" => "interrupted", "windows" => [{"window_name" => "one", "panes" => [{}]}]}
        primary = Interrupt.new("private-first-interrupt")
        second = RuntimeError.new("private-second-interrupt")
        trace = TracePoint.new(:return, :call) do |point|
          next unless point.self == server || point.self.is_a?(LibTmux::Session)
          if point.event == :return && point.method_id == :new_session
            Thread.current.raise(primary)
          elsif point.event == :call && point.method_id == :kill
            trace.disable
            Thread.current.raise(second)
          end
        end
        begin
          trace.enable
          error = assert_raises(LibTmux::Workspace::ApplyError) do
            workspace(source, File.dirname(fixture.socket_path)).plan.apply(server: server, compensate: true)
          end
          assert_equal "Interrupt", error.failure_class
          assert_equal 3, error.result.created_refs.length
          assert_equal :completed, error.result.compensation
          assert_equal ["fixture"], server.snapshot.sessions.map(&:name)
          refute_includes error.full_message, "private-"
        ensure
          trace.disable
        end
      end
    end
  end

  def test_compensation_preserves_a_borrowed_window_moved_into_the_created_session
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        borrowed = server.list_window_links.fetch(0)
        original = LibTmux::Options.instance_method(:set)
        LibTmux::Options.define_method(:set) do |*arguments, **options|
          new_session = server.list_sessions.find { |session| session.id != borrowed.ref.session_id }
          borrowed.move(session: new_session.ref, index: 9)
          raise LibTmux::TransportError.new("acquisition failed", delivery: :not_sent)
        end
        begin
          source = {"session_name" => "borrowed-survivor", "windows" => [{"window_name" => "one", "panes" => [{}]}]}
          error = assert_raises(LibTmux::Workspace::ApplyError) do
            workspace(source, File.dirname(fixture.socket_path)).plan.apply(server: server, compensate: true)
          end
          assert_equal :failed, error.result.compensation
          assert_includes server.list_windows.map(&:id), borrowed.id
          assert_equal 3, error.result.created_refs.length
        ensure
          LibTmux::Options.define_method(:set, original)
        end
      end
    end
  end

  def test_compensation_removes_only_a_complete_positively_identified_new_topology
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        original = LibTmux::Options.instance_method(:set)
        LibTmux::Options.define_method(:set) do |*arguments, **options|
          raise LibTmux::TransportError.new("option dispatch failed", delivery: :not_sent)
        end
        begin
          source = {"session_name" => "known", "windows" => [{"window_name" => "one", "panes" => [{}]}]}
          error = assert_raises(LibTmux::Workspace::ApplyError) do
            workspace(source, File.dirname(fixture.socket_path)).plan.apply(server: server, compensate: true)
          end
          assert_equal 3, error.result.created_refs.length
          assert_equal [1], error.result.completed_steps
          assert_equal :completed, error.result.compensation
          assert_equal ["fixture"], server.snapshot.sessions.map(&:name)
        ensure
          LibTmux::Options.define_method(:set, original)
        end
      end
    end
  end

  def test_compensation_preserves_a_borrowed_pane_joined_into_a_created_window
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        borrowed = server.list_panes.fetch(0)
        original = LibTmux::Options.instance_method(:set)
        LibTmux::Options.define_method(:set) do |*arguments, **options|
          destination = server.list_panes.find { |pane| pane.id != borrowed.id }
          borrowed.join(destination.ref, direction: :horizontal)
          raise LibTmux::TransportError.new("option dispatch failed", delivery: :not_sent)
        end
        begin
          source = {"session_name" => "borrowed-pane", "windows" => [{"window_name" => "one", "panes" => [{}]}]}
          error = assert_raises(LibTmux::Workspace::ApplyError) do
            workspace(source, File.dirname(fixture.socket_path)).plan.apply(server: server, compensate: true)
          end
          assert_equal :failed, error.result.compensation
          assert_includes server.list_panes.map(&:id), borrowed.id
          refute_includes error.result.created_refs.values, borrowed.ref
        ensure
          LibTmux::Options.define_method(:set, original)
        end
      end
    end
  end

  private

  def workspace(source, directory)
    LibTmux::Workspace.parse(JSON.generate(source), format: :json, base_directory: directory)
  end

  def receipt_command(path)
    source = 'UNIXSocket.open(ARGV.fetch(0)) { |io| io.write(Marshal.dump([Dir.pwd, ENV["ROOT"]])) }'
    [Gem.ruby, "--disable=rubyopt,gems", "-rsocket", "-e", source, path].shelljoin
  end
end
