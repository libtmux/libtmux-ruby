# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"

class ServerControlTest < Minitest::Test
  def test_server_owns_bounded_control_clients_and_closes_pending_exchanges
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path, max_controls: 1) do |server|
        session = server.list_sessions.first
        control = server.open_control(session: session.ref)
        assert_equal "ready\n", control.exchange("display-message -p ready", timeout: 0.5).blocks.last.body
        assert_raises(LibTmux::CapacityError) { server.open_control(session: session.ref) }
        assert server.list_clients.any? { |client| client[:pid] == control.pid && client[:control] }
        control.close
        replacement = server.open_control(session: session.ref)
        request = Thread.new do
          replacement.exchange("wait-for -S scoped-ready ; wait-for scoped-held", timeout: 0.5)
        rescue LibTmux::Error => error
          error
        end
        begin
          assert fixture.tmux("wait-for", "scoped-ready").last.success?
          server.close
          assert request.join(0.5), "server close did not wake the pending exchange"
          assert_instance_of LibTmux::ClosedError, request.value
          assert_raises(Errno::ECHILD) { Process.waitpid(replacement.pid, Process::WNOHANG) }
          assert fixture.tmux("has-session", "-t", "fixture").last.success?
        ensure
          request.join(0.5)
        end
      end
    end
  end

  def test_control_block_preserves_result_exception_and_binding_checks
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.list_sessions.first
        pid = nil
        assert_equal :returned, server.open_control(session: session.ref) { |control| pid = control.pid; :returned }
        assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
        original = RuntimeError.new("caller failure")
        assert_same original, assert_raises(RuntimeError) { server.open_control(session: session.ref) { raise original } }
        assert_raises(LibTmux::TargetNotFoundError) { server.open_control(session: server.list_windows.first.ref) }
      end
    end
  end
end
