# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"
require "rbconfig"
require "socket"
require "tmpdir"

class ProcessExecutorTest < Minitest::Test
  def test_preserves_literal_arguments_and_clears_tmux_environment
    arguments = ["", ";", "a\nb", "\\", "$(false)", "x y", "\"'", "#{35.chr}{pid}"]
    source = "Marshal.dump([ARGV, ENV.values_at('TMUX', 'TMUX_PANE')], STDOUT)"
    argv = ruby(source, *arguments)
    result = executor.run(argv, env: {"TMUX" => "borrowed", "TMUX_PANE" => "%42"})

    assert_equal [arguments, [nil, nil]], Marshal.load(result.stdout)
    assert result.success?
    assert_equal :observed, result.delivery
    assert_operator result.elapsed_seconds, :>=, 0
    assert result.argv.frozen?
    assert result.argv.all?(&:frozen?)
    refute_same argv, result.argv
    assert_reaped(result.pid)
  end

  def test_preserves_binary_streams_and_raw_nonzero_status
    result = executor.run(ruby("STDOUT.write([255, 10, 10].pack('C*')); STDERR.write([0, 254].pack('C*')); exit 17"))

    assert_equal "\xff\n\n".b, result.stdout
    assert_equal "\x00\xfe".b, result.stderr
    assert_equal Encoding::BINARY, result.stdout.encoding
    assert_equal Encoding::BINARY, result.stderr.encoding
    assert result.stdout.frozen?
    assert result.stderr.frozen?
    assert_equal 17, result.status.exitstatus
    refute result.success?
    assert_raises(LibTmux::FieldDecodeError) { result.text }
    assert_equal "\uFFFD\n\n", result.text(invalid: :replace)
    assert_reaped(result.pid)
  end

  def test_drains_both_streams_while_writing_large_stdin
    source = <<~RUBY
      STDOUT.binmode
      STDERR.binmode
      writers = [Thread.new { STDOUT.write('o' * 262_144) }, Thread.new { STDERR.write('e' * 262_144) }]
      input = STDIN.read
      writers.each(&:join)
      STDOUT.write(input)
    RUBY
    input = ("\x00\xff".b * 131_072)
    result = executor.run(ruby(source), input: input)

    assert result.success?
    assert_equal "o".b * 262_144 + input, result.stdout
    assert_equal "e".b * 262_144, result.stderr
    assert_reaped(result.pid)
  end

  def test_rejects_nul_before_spawning
    error = assert_raises(ArgumentError) { executor.run(["unavailable\0private-path"]) }
    refute_includes error.message, "private-path"
  end

  def test_expired_deadline_is_known_not_sent
    error = assert_raises(LibTmux::DeadlineExceeded) { executor.run(["must-not-spawn"], timeout: 0) }

    assert_equal :not_sent, error.delivery
    assert_equal :admission, error.phase
    assert_nil error.pid
  end

  def test_output_limit_retires_and_reaps_the_child
    error = assert_raises(LibTmux::CapacityError) do
      executor(stdout_limit: 1024).run(ruby("STDOUT.sync = true; loop { STDOUT.write('x' * 8192) }"))
    end

    assert_equal :possibly_sent, error.delivery
    assert_equal :read, error.phase
    assert_empty error.cleanup_errors
    assert_reaped(error.pid)
  end

  def test_cancellation_before_dispatch_never_spawns
    cancellation = LibTmux::Internal::Cancellation.new
    cancellation.cancel
    error = assert_raises(LibTmux::Cancelled) { executor.run(["must-not-spawn"], cancel: cancellation) }

    assert_equal :not_sent, error.delivery
    assert_equal :admission, error.phase
    assert_nil error.pid
  ensure
    cancellation&.close
  end

  def test_cancellation_escalates_and_reaps_a_child_ignoring_term
    cancellation = LibTmux::Internal::Cancellation.new
    with_child_readiness do |ready, environment|
      worker = task do
        executor(cleanup_timeout: 0.1).run(ruby(<<~RUBY), env: environment, cancel: cancellation)
          trap('TERM') {}
          File.write(ENV.fetch('READY'), Process.pid.to_s + "\n")
          input, output = IO.pipe
          input.read(1)
        RUBY
      end
      pid = Integer(read_event(ready), 10)
      20.times { cancellation.cancel }
      assert worker.join(0.5), "cancellation did not retire the owned client"
      error = worker.value

      assert_instance_of LibTmux::Cancelled, error
      assert_equal :possibly_sent, error.delivery
      assert_equal pid, error.pid
      assert_empty error.cleanup_errors
      assert_reaped(pid)
    ensure
      worker&.kill
      worker&.join(0.5)
    end
  ensure
    cancellation&.close
  end

  def test_deadline_after_dispatch_reports_possible_effects
    with_child_readiness do |ready, environment|
      worker = task do
        executor.run(ruby(<<~RUBY), env: environment, timeout: 0.1)
          File.write(ENV.fetch('READY'), Process.pid.to_s + "\n")
          input, output = IO.pipe
          input.read(1)
        RUBY
      end
      pid = Integer(read_event(ready), 10)
      assert worker.join(0.5), "deadline did not retire the owned client"
      error = worker.value

      assert_instance_of LibTmux::DeadlineExceeded, error
      assert_equal :possibly_sent, error.delivery
      assert_equal pid, error.pid
      assert_empty error.cleanup_errors
      assert_reaped(pid)
    ensure
      worker&.kill
      worker&.join(0.5)
    end
  end

  def test_drain_deadline_bounds_a_pipe_retained_after_child_exit
    Dir.mktmpdir("libtmux-ruby-") do |directory|
      path = File.join(directory, "transfer")
      UNIXServer.open(path) do |server|
        worker = task do
          executor(drain_timeout: 0.04).run(ruby(<<~RUBY), env: {"TRANSFER" => path})
            require 'socket'
            socket = UNIXSocket.new(ENV.fetch('TRANSFER'))
            socket.send_io(STDOUT)
            socket.close
          RUBY
        end
        assert IO.select([server], nil, nil, 0.5), "child did not connect for pipe transfer"
        connection = server.accept
        assert IO.select([connection], nil, nil, 0.5), "child did not transfer its pipe"
        retained = connection.recv_io
        connection.close
        assert worker.join(0.5), "another pipe owner prevented bounded command cleanup"
        error = worker.value

        assert_instance_of LibTmux::DeadlineExceeded, error
        assert_equal :drain, error.phase
        assert_equal :observed, error.delivery
        assert_empty error.cleanup_errors
        assert_reaped(error.pid)
        refute retained.closed?
      ensure
        retained&.close
        connection&.close unless connection&.closed?
        worker&.kill
        worker&.join(0.5)
      end
    end
  end

  def test_thread_exception_survives_owned_cleanup
    failure = RuntimeError.new("caller cancelled")
    with_child_readiness do |ready, environment|
      worker = task do
        executor.run(ruby(<<~RUBY), env: environment)
          File.write(ENV.fetch('READY'), Process.pid.to_s + "\n")
          input, output = IO.pipe
          input.read(1)
        RUBY
      end
      pid = Integer(read_event(ready), 10)
      worker.raise(failure)
      assert worker.join(0.5), "interrupted caller did not retire its client"

      assert_same failure, worker.value
      assert_reaped(pid)
    ensure
      worker&.kill
      worker&.join(0.5)
    end
  end

  def test_repeated_thread_cancellation_does_not_replace_the_first_failure
    original = RuntimeError.new("first cancellation")
    later = RuntimeError.new("cleanup cancellation")
    release = Queue.new
    observer = nil
    with_child_readiness do |ready, environment|
      trace = TracePoint.new(:c_call) do |event|
        next unless event.method_id == :wait2 && !observer

        observer = Thread.current
        ready.syswrite("reaping\n")
        release.pop
      end
      trace.enable
      worker = task do
        executor(cleanup_timeout: 0.15).run(ruby(<<~RUBY), env: environment)
          input, output = IO.pipe
          trap('TERM') {}
          File.write(ENV.fetch('READY'), Process.pid.to_s + "\n")
          input.read(1)
        RUBY
      end
      pid = Integer(read_event(ready), 10)
      worker.raise(original)
      assert_equal "reaping", read_event(ready)
      worker.raise(later)
      release << true
      assert worker.join(0.5), "repeated cancellation stranded cleanup"

      assert_same original, worker.value
      assert_reaped(pid)
    ensure
      trace&.disable
      release << true
      worker&.kill
      worker&.join(0.5)
      observer&.join(0.5)
    end
  end

  def test_caps_request_bytes_before_dispatch
    error = assert_raises(LibTmux::CapacityError) do
      executor.run(ruby("exit 0"), input: "x" * ((1 << 20) + 1))
    end
    assert_equal :not_sent, error.delivery
    assert_equal :admission, error.phase
    assert_nil error.pid

    error = assert_raises(LibTmux::CapacityError) { executor.run(["x" * (1 << 18)]) }
    assert_equal :not_sent, error.delivery
    assert_equal :admission, error.phase
    assert_nil error.pid
  end

  def test_spawn_failure_closes_descriptors_and_redacts_the_executable
    before = Dir.children("/dev/fd").length
    error = assert_raises(LibTmux::TransportError) do
      executor.run(["/unavailable/private-command-argument"])
    end

    assert_equal :not_sent, error.delivery
    assert_equal :spawn, error.phase
    assert_nil error.pid
    assert_nil error.cause
    assert_empty error.cleanup_errors
    refute_includes error.inspect, "private-command-argument"
    assert_equal before, Dir.children("/dev/fd").length
  end

  def test_exit_observation_leaves_child_waitable_until_owner_reaps
    wait = LibTmux::Internal::ProcessWait.new
    pid = Process.spawn(*ruby("exit 17"), out: File::NULL, err: File::NULL, close_others: true)
    observer = task { wait.observe(pid) }
    assert observer.join(0.5), "exit observation did not complete"
    raise observer.value if observer.value.is_a?(Exception)
    assert_equal 1, Process.kill(0, pid)
    assert_equal 1, Process.kill("TERM", pid)

    waited = begin
      Process.waitpid2(pid, Process::WNOHANG)
    rescue Errno::ECHILD
      nil
    end
    assert waited, "exit observer reaped the client before its owner could finish signalling"
    assert_equal pid, waited.first
    assert_equal 17, waited.last.exitstatus
    assert_reaped(pid)
  ensure
    if pid && observer && !observer.alive?
      begin
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  def test_shared_child_owner_reaps_only_after_final_signal_handoff
    assert LibTmux::Internal.const_defined?(:OwnedChild), "shared child owner is missing"
    child = LibTmux::Internal::OwnedChild.new
    pid = Process.spawn(*ruby("exit 17"), out: File::NULL, err: File::NULL, close_others: true)
    child.spawned(pid)
    assert IO.select([child.reader], nil, nil, 0.5), "child observation did not notify its owner"
    assert child.observed?
    refute child.join(0), "observation must retain the wait obligation until final signalling"
    LibTmux::Internal::ProcessWait.new.observe(pid)
    child.finish_signalling
    assert_nil child.signal("KILL"), "retired signal permission must never use a recycled PID"
    assert child.join(0.5), "native reaping bridge did not finish"
    assert_equal 17, child.status.exitstatus
    assert_nil child.observation_error
    assert_nil child.retirement_error
    assert_reaped(pid)
  ensure
    if child
      child.signal("KILL")
      child.finish_signalling
      child.join(0.5)
      child.close
    end
  end

  def test_observed_exit_wins_cancellation_before_native_status_publication
    cancel = LibTmux::Internal::Cancellation.new
    release = Queue.new
    handed_off = false
    observer = nil
    trace = TracePoint.new(:return, :c_call) do |event|
      if event.event == :return && event.defined_class == LibTmux::Internal::OwnedChild &&
          event.method_id == :finish_signalling && !handed_off
        handed_off = true
        cancel.cancel
      elsif event.event == :c_call && event.method_id == :wait2 && !observer
        observer = Thread.current
        release.pop
      elsif event.event == :c_call && event.method_id == :select && handed_off
        release << true
      end
    end
    trace.enable
    worker = task { executor(cleanup_timeout: 0.02).run(ruby('STDOUT.write("done")'), cancel: cancel) }
    assert worker.join(0.5), "observed command did not finish its bounded drain"
    assert_instance_of LibTmux::CommandResult, worker.value
    assert_equal "done", worker.value.stdout
    assert worker.value.success?
    assert_reaped(worker.value.pid)
  ensure
    trace&.disable
    release << true if release
    worker&.join(0.5)
    observer&.join(0.5)
    cancel&.close
  end

  def test_incomplete_cleanup_retains_the_obligation_to_reap
    before = Thread.list
    cancellation = LibTmux::Internal::Cancellation.new
    with_child_readiness do |ready, environment|
      worker = task do
        executor(cleanup_timeout: 0.000000001).run(ruby(<<~RUBY), env: environment, cancel: cancellation)
          trap('TERM') {}
          File.write(ENV.fetch('READY'), Process.pid.to_s + "\n")
          input, output = IO.pipe
          input.read(1)
        RUBY
      end
      pid = Integer(read_event(ready), 10)
      cancellation.cancel
      assert worker.join(0.5), "cleanup did not respect its deadline"
      assert_instance_of LibTmux::Cancelled, worker.value
      (Thread.list - before).each do |thread|
        assert thread.join(0.5), "an incomplete cleanup lost its owned retirement task"
      end
      assert_reaped(pid)
    ensure
      worker&.kill
      worker&.join(0.5)
      begin
        Process.waitpid(pid, Process::WNOHANG) if pid
      rescue Errno::ECHILD
        nil
      end
    end
  ensure
    cancellation&.close
  end

  def test_fork_child_detaches_cancellation_without_waking_parent
    cancellation = LibTmux::Internal::Cancellation.new
    child = fork do
      cancellation.detach
      exit! 0
    rescue Exception
      exit! 17
    end
    _, status = Process.wait2(child)

    assert status.success?, "fork child could not detach inherited token descriptors"
    refute cancellation.cancelled?
    assert_nil IO.select([cancellation.reader], nil, nil, 0), "child wrote to the parent's cancellation pipe"
    cancellation.cancel
    assert IO.select([cancellation.reader], nil, nil, 0)
  ensure
    cancellation&.close
  end

  def test_interrupted_exit_observer_does_not_abandon_a_live_owned_child
    release = Queue.new
    # Raise in the real observer thread without substituting the child or waiter.
    trace = TracePoint.new(:call) do |event|
      if event.defined_class == LibTmux::Internal::ProcessWait && event.method_id == :observe
        release.pop
        raise IOError, "exit observer failed"
      end
    end
    with_child_readiness do |ready, environment|
      trace.enable
      worker = task do
        executor(cleanup_timeout: 0.1).run(ruby(<<~RUBY), env: environment)
          trap('TERM') {}
          File.write(ENV.fetch('READY'), Process.pid.to_s + "\n")
          input, output = IO.pipe
          input.read(1)
        RUBY
      end
      pid = Integer(read_event(ready), 10)
      release << true
      assert worker.join(0.5), "failed exit observer did not release command ownership"
      assert_instance_of LibTmux::TransportError, worker.value
      assert_reaped(pid)
    ensure
      trace.disable
      release << true
      worker&.kill
      worker&.join(0.5)
      if pid
        begin
          unless Process.waitpid(pid, Process::WNOHANG)
            Process.kill("KILL", pid)
            Process.waitpid(pid)
          end
        rescue Errno::ECHILD, Errno::ESRCH
          nil
        end
      end
    end
  end

  def test_late_observer_failure_receives_reaping_ownership_after_final_signal
    release = Queue.new
    selected = nil
    cancellation = LibTmux::Internal::Cancellation.new
    trace = TracePoint.new(:call) do |event|
      if event.defined_class == LibTmux::Internal::ProcessWait && event.method_id == :observe && !selected
        selected = Thread.current
        release.pop
        raise IOError, "late exit observer failure"
      end
    end
    with_child_readiness do |ready, environment|
      trace.enable
      worker = task do
        executor(cleanup_timeout: 0.1).run(ruby(<<~RUBY), env: environment, cancel: cancellation)
          trap('TERM') {}
          File.write(ENV.fetch('READY'), Process.pid.to_s + "\n")
          input, output = IO.pipe
          input.read(1)
        RUBY
      end
      pid = Integer(read_event(ready), 10)
      cancellation.cancel
      witness = task { LibTmux::Internal::ProcessWait.new.observe(pid) }
      assert witness.join(0.5), "final kill did not make the child waitable"
      raise witness.value if witness.value.is_a?(Exception)
      release << true
      assert worker.join(0.5), "late observer failure lost its retirement token"
      assert_instance_of LibTmux::Cancelled, worker.value
      assert selected.join(0.5), "late observer did not retain its reaping obligation"
      assert_reaped(pid)
    ensure
      trace.disable
      release << true
      worker&.kill
      worker&.join(0.5)
      selected&.join(0.5)
      witness&.join(0.5)
    end
  ensure
    cancellation&.close
  end

  private

  def executor(**options)
    LibTmux::Internal::ProcessExecutor.new(**options)
  end

  def ruby(source, *arguments)
    [RbConfig.ruby, "--disable=rubyopt,gems", "-e", source, "--", *arguments]
  end

  def assert_reaped(pid)
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  def task
    Thread.new do
      yield
    rescue Exception => error
      error
    end
  end

  def with_child_readiness
    Dir.mktmpdir("libtmux-ruby-") do |directory|
      path = File.join(directory, "ready")
      File.mkfifo(path, 0o600)
      File.open(path, File::RDWR | File::NONBLOCK) do |ready|
        yield ready, {"READY" => path}
      end
    end
  end

  def read_event(io)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    value = +""
    until value.end_with?("\n")
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      available = remaining.positive? && IO.select([io], nil, nil, remaining)
      assert available, "child event did not arrive"
      byte = io.read_nonblock(1, exception: false)
      value << byte if byte.is_a?(String)
    end
    value.chomp
  end
end
