# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"
require "libtmux/owned" if File.exist?(File.expand_path("../../gems/libtmux/lib/libtmux/owned.rb", __dir__))

class StartupTest < Minitest::Test
  def test_log_readiness_disables_logging_before_exposing_the_owned_server
    readiness = LibTmux::Internal.const_get(:SocketReadiness, false)
    original = readiness.method(:new)
    log_readiness = nil
    readiness.define_singleton_method(:new) do |directory|
      log_readiness = LibTmux::Internal.const_get(:LogSocketReadiness, false).new(directory)
    end
    path = pid = nil
    LibTmux::Server.start(timeout: 0.5) do |server|
      path = File.dirname(server.endpoint.socket_path)
      pid = Integer(server.run(["display-message", "-p", '#{pid}']).text)
      assert log_readiness.stopped?
      assert_operator log_readiness.bytes_read, :>, 0
      assert_operator log_readiness.bytes_read, :<=, 1 << 20
      assert_empty Dir[File.join(path, "*.log")]
      assert_equal "ready-without-logging\n", server.run(["display-message", "-p", "ready-without-logging"]).text
      assert_empty Dir[File.join(path, "*.log")]
    end
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    refute File.exist?(path)
  ensure
    readiness&.define_singleton_method(:new, original) if original
  end

  def test_oversized_startup_log_fails_closed_and_reaps_its_writer
    readiness = LibTmux::Internal.const_get(:SocketReadiness, false)
    original = readiness.method(:new)
    readiness.define_singleton_method(:new) do |directory|
      LibTmux::Internal.const_get(:LogSocketReadiness, false).new(directory)
    end
    Dir.mktmpdir("libtmux-ruby-log-writer-") do |directory|
      executable = File.join(directory, "writer")
      record = File.join(directory, "owned-path")
      File.write(executable, "#!#{RbConfig.ruby} --disable=rubyopt,gems\n" \
        "File.write(#{record.inspect}, Dir.pwd)\n" \
        "File.binwrite(\"tmux-server-\#{Process.pid}.log\", 'x' * ((1 << 20) + 1))\nIO.select([])\n")
      File.chmod(0o700, executable)
      error = assert_raises(LibTmux::CapacityError) { LibTmux::Server.start(executable: executable, timeout: 0.5) }
      assert_equal :possibly_sent, error.delivery
      assert_equal :startup, error.phase
      assert_raises(Errno::ECHILD) { Process.waitpid(error.pid, Process::WNOHANG) }
      refute File.exist?(File.read(record))
      assert_empty error.cleanup_errors
    end
  ensure
    readiness&.define_singleton_method(:new, original) if original
  end

  def test_explicit_start_owns_an_empty_daemon_and_cleanup_preserves_borrowed_server
    owned_path = daemon_pid = nil
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |borrowed|
        LibTmux::Server.start do |server|
          assert server.owned?
          refute borrowed.owned?
          owned_path = server.endpoint.socket_path
          assert_equal 0o700, File.stat(File.dirname(owned_path)).mode & 0o777
          assert_equal [], server.list_sessions.to_a
          daemon_pid = Integer(server.run(["display-message", "-p", '#{pid}']).text)
          assert_operator daemon_pid, :>, 0
          created = server.new_session(name: "owned", command: ["cat"])
          assert_equal [created.ref], server.list_sessions.map(&:ref)
        end
        assert borrowed.run(["list-sessions"]).success?
      end
    end
    assert_raises(Errno::ECHILD) { Process.waitpid(daemon_pid, Process::WNOHANG) }
    refute File.exist?(File.dirname(owned_path))
  end

  def test_block_failure_and_pre_cancel_leave_no_owned_daemon_or_directory
    failure = RuntimeError.new("caller failure")
    path = pid = nil
    observed = assert_raises(RuntimeError) do
      LibTmux::Server.start do |server|
        path = server.endpoint.socket_path
        pid = Integer(server.run(["display-message", "-p", '#{pid}']).text)
        raise failure
      end
    end
    assert_same failure, observed
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    refute File.exist?(File.dirname(path))
    token = LibTmux::Internal::Cancellation.new
    begin
      token.cancel
      error = assert_raises(LibTmux::Cancelled) { LibTmux::Server.start(cancel: token) }
      assert_equal :not_sent, error.delivery
      assert_nil error.pid
    ensure
      token.close
    end
  end

  def test_early_daemon_exit_is_reported_and_reaped
    Dir.mktmpdir("libtmux-ruby-early-exit-") do |directory|
      executable = File.join(directory, "exit")
      File.write(executable, "#!#{RbConfig.ruby} --disable=rubyopt,gems\nexit 1\n")
      File.chmod(0o700, executable)
      error = assert_raises(LibTmux::TransportError) { LibTmux::Server.start(executable: executable) }
      assert_equal :startup, error.phase
      assert_equal :possibly_sent, error.delivery
      assert_operator error.pid, :>, 0
      assert_raises(Errno::ECHILD) { Process.waitpid(error.pid, Process::WNOHANG) }
      assert_empty error.cleanup_errors
    end
  end

  def test_no_block_constructor_interrupt_retires_daemon_during_ownership_transfer
    daemon_class = LibTmux::Internal.const_get(:OwnedDaemon, false)
    constructor = daemon_class.method(:new)
    failure = Interrupt.new("cancel constructor transfer")
    owned = nil
    factory = lambda do |**options|
      owned = constructor.call(**options)
      Thread.current.raise failure
      owned
    end
    begin
      daemon_class.define_singleton_method(:new, factory)
      observed = assert_raises(Interrupt) { LibTmux::Server.start }
      assert_same failure, observed
      pid = owned.instance_variable_get(:@child).pid
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      refute File.exist?(File.dirname(owned.endpoint.socket_path))
    ensure
      daemon_class.singleton_class.remove_method(:new)
      owned&.close
    end
  end

  def test_cancel_after_spawn_retires_unready_child_and_owned_directory
    token = LibTmux::Internal::Cancellation.new
    held_input, writer = IO.pipe
    original = Process.method(:spawn)
    path = nil
    replacement = lambda do |*argv, **options|
      path = argv.fetch(argv.index("-S") + 1)
      child = original.call("/bin/cat", in: held_input, out: File::NULL, err: File::NULL, close_others: true)
      token.cancel
      child
    end
    begin
      Process.define_singleton_method(:spawn, replacement)
      error = assert_raises(LibTmux::Cancelled) { LibTmux::Server.start(cancel: token) }
      assert_equal :possibly_sent, error.delivery
      assert_raises(Errno::ECHILD) { Process.waitpid(error.pid, Process::WNOHANG) }
      refute File.exist?(File.dirname(path))
    ensure
      Process.define_singleton_method(:spawn, original)
      held_input.close
      writer.close
      token.close
    end
  end

  def test_repeated_interrupt_during_close_preserves_first_error_and_reaps
    entered, release = Queue.new, Queue.new
    first, second = Interrupt.new("first cancellation"), Interrupt.new("cleanup cancellation")
    path = pid = nil
    worker = Thread.new do
      LibTmux::Server.start do |server|
        path = server.endpoint.socket_path
        child = server.instance_variable_get(:@daemon).instance_variable_get(:@child)
        pid = child.pid
        original = child.method(:signal)
        child.define_singleton_method(:signal) do |name|
          if name == "TERM"
            entered << true
            release.pop
          end
          original.call(name)
        end
        raise first
      end
    rescue Exception => error
      error
    end
    begin
      assert entered.pop(timeout: 0.5), "daemon close was not entered"
      worker.raise second
      release << true
      assert worker.join(0.5), "daemon cleanup did not settle"
      assert_same first, worker.value
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      refute File.exist?(File.dirname(path))
    ensure
      release << true
      worker.join(0.5)
    end
  end

  def test_forked_close_cannot_retire_parent_daemon
    LibTmux::Server.start do |server|
      reader, writer = IO.pipe
      child = fork do
        reader.close
        server.close
        writer.write("detached")
        writer.close
        exit! 0
      end
      writer.close
      begin
        assert IO.select([reader], nil, nil, 0.5), "fork child did not detach"
        assert_equal "detached", reader.read
        assert Process.wait2(child).last.success?
        assert server.run(["display-message", "-p", "still-owned"]).success?
        assert File.socket?(server.endpoint.socket_path)
      ensure
        reader.close
      end
    end
  end

  def test_retired_observer_fault_is_reported_once_and_close_remains_idempotent
    server = LibTmux::Server.start
    child = server.instance_variable_get(:@daemon).instance_variable_get(:@child)
    original = child.method(:observation_error)
    path = server.endpoint.socket_path
    child.define_singleton_method(:observation_error) { Errno::EINVAL.new("native observer failure") }
    begin
      error = assert_raises(LibTmux::TransportError) { server.close }
      refute_empty error.cleanup_errors
      assert_nil server.close
      refute File.exist?(File.dirname(path))
      assert_raises(Errno::ECHILD) { Process.waitpid(child.pid, Process::WNOHANG) }
    ensure
      child.define_singleton_method(:observation_error, original)
      server.close
    end
  end

  def test_failed_spawn_is_typed_redacted_and_removes_private_directory
    original = Process.method(:spawn)
    path = nil
    Process.define_singleton_method(:spawn) do |*argv, **options|
      path = argv.fetch(argv.index("-S") + 1)
      raise Errno::ENOENT, "private-executable-name"
    end
    begin
      error = assert_raises(LibTmux::TransportError) { LibTmux::Server.start }
      assert_equal :not_sent, error.delivery
      assert_equal :spawn, error.phase
      assert_nil error.pid
      refute_includes error.full_message, "private-executable-name"
      refute File.exist?(File.dirname(path))
    ensure
      Process.define_singleton_method(:spawn, original)
    end
  end
end
