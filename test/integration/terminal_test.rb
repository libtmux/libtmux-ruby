# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "pty"
require "io/console"
require "libtmux"
require "libtmux/terminal" if File.exist?(File.expand_path("../../gems/libtmux/lib/libtmux/terminal.rb", __dir__))

class TerminalTest < Minitest::Test
  def test_explicit_terminal_attach_and_user_detach_return_final_status
    LibTmuxTest::TmuxFixture.open do |fixture|
      # One PTY write represents key presses, not a paste detected by timing.
      assert fixture.tmux("set-option", "-g", "assume-paste-time", "0").last.success?
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.list_sessions.first
        PTY.open do |master, slave|
          slave.winsize = [24, 80]
          before = slave.echo?
          assert server.run(["set-hook", "-g", "client-attached", "wait-for -S terminal-attached"]).success?
          worker = Thread.new { server.attach(session: session.ref, terminal: slave, term: "xterm", timeout: 1) }
          begin
            assert fixture.tmux("wait-for", "terminal-attached").last.success?
            assert_equal 1, server.list_clients.length
            master.write("\x02d")
            assert worker.join(0.5), "terminal client did not detach"
            result = worker.value
            assert_instance_of LibTmux::TerminalResult, result
            assert result.success?
            assert_equal :observed, result.delivery
            assert_raises(Errno::ECHILD) { Process.waitpid(result.pid, Process::WNOHANG) }
            assert_equal before, slave.echo?
            refute slave.closed?
            assert_empty server.list_clients
          ensure
            server.close
            worker.join(0.5)
          end
        end
      end
    end
  end

  def test_server_close_cancels_only_its_terminal_client_and_restores_borrowed_tty
    LibTmuxTest::TmuxFixture.open do |fixture|
      server = LibTmux::Server.open(socket_path: fixture.socket_path)
      PTY.open do |master, slave|
        slave.winsize = [24, 80]
        before = slave.echo?
        session = server.list_sessions.first
        assert server.run(["set-hook", "-g", "client-attached", "wait-for -S terminal-close"]).success?
        worker = Thread.new do
          server.attach(session: session.ref, terminal: slave, term: "xterm")
        rescue LibTmux::Cancelled => error
          error
        end
        begin
          assert fixture.tmux("wait-for", "terminal-close").last.success?
          server.close
          assert worker.join(0.5), "closed terminal client did not retire"
          error = worker.value
          assert_instance_of LibTmux::Cancelled, error
          assert_equal :possibly_sent, error.delivery
          assert_raises(Errno::ECHILD) { Process.waitpid(error.pid, Process::WNOHANG) }
          assert_equal before, slave.echo?
          assert fixture.tmux("list-sessions").last.success?
          refute slave.closed?
        ensure
          server.close
          worker.join(0.5)
        end
      end
    end
  end

  def test_terminal_is_explicit_and_pre_cancel_does_not_attach
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.list_sessions.first
        File.open(File::NULL, "w") do |file|
          assert_raises(ArgumentError) { server.attach(session: session.ref, terminal: file, term: "xterm") }
        end
        PTY.open do |master, slave|
          token = LibTmux::Internal::Cancellation.new
          begin
            token.cancel
            failure = assert_raises(LibTmux::Cancelled) do
              server.attach(session: session.ref, terminal: slave, term: "xterm", cancel: token)
            end
            assert_equal :not_sent, failure.delivery
            assert_nil failure.pid
            assert_empty server.list_clients
          ensure
            token.close
          end
        end
      end
    end
  end

  def test_spawn_failure_is_typed_redacted_and_retires_observer
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.list_sessions.first
        PTY.open do |master, slave|
          original = Process.method(:spawn)
          before = Thread.list
          Process.define_singleton_method(:spawn) { |*args, **options| raise Errno::ENOENT, "private-executable-name" }
          begin
            error = assert_raises(LibTmux::TransportError) do
              server.attach(session: session.ref, terminal: slave, term: "xterm")
            end
            assert_equal :not_sent, error.delivery
            assert_equal :spawn, error.phase
            assert_nil error.pid
            refute_includes error.full_message, "private-executable-name"
            assert_empty Thread.list - before
            refute slave.closed?
          ensure
            Process.define_singleton_method(:spawn, original)
          end
        end
      end
    end
  end
end
