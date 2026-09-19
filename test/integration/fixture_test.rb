# frozen_string_literal: true

require "minitest/autorun"
require "libtmux/process_wait"
require_relative "../support/tmux_fixture"

class TmuxFixtureTest < Minitest::Test
  def test_explicit_executable_selects_both_owned_daemon_and_client
    executable = ENV.fetch("LIBTMUX_TEST_TMUX") do
      ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |part| File.join(part, "tmux") }
        .find { |path| File.file?(path) && File.executable?(path) }
    end
    launches = []
    trace = TracePoint.new(:call) do |event|
      if event.defined_class == LibTmuxTest::TmuxFixture && event.method_id == :spawn_owned
        launches << event.binding.local_variable_get(:arguments).first
      end
    end
    fixture = LibTmuxTest::TmuxFixture.new(executable: executable)
    trace.enable do
      fixture.start
      assert fixture.tmux("has-session", "-t", "fixture").last.success?
    end
    assert_equal executable, fixture.executable
    assert_operator launches.length, :>=, 3
    assert launches.all? { |value| value == executable }
  ensure
    trace&.disable
    fixture&.close
  end

  def test_failed_observer_still_retires_its_real_child
    release = Queue.new
    trace = TracePoint.new(:call) do |event|
      if event.defined_class == LibTmux::Internal::ProcessWait && event.method_id == :observe
        release.pop
        raise IOError, "fixture observer failure"
      end
    end
    fixture = LibTmuxTest::TmuxFixture.new
    fixture.start
    trace.enable
    child = fixture.send(:spawn_owned, Gem.ruby, "--disable=rubyopt,gems", "-e",
      'trap("TERM") {}; STDOUT.write("ready\n"); STDOUT.flush; input, output = IO.pipe; input.read(1)')
    fixture.instance_variable_get(:@clients)[child.last.pid] = child
    assert IO.select([child[1]], nil, nil, 0.5), "owned helper did not start"
    assert_equal "ready\n", child[1].gets
    release << true
    trace.disable
    error = assert_raises(LibTmuxTest::TmuxFixture::Error) { fixture.close }
    assert error.cleanup_errors.any? { |entry| entry.include?("IOError") }
    assert_raises(Errno::ECHILD) { Process.waitpid(child.last.pid, Process::WNOHANG) }
    assert child.take(3).all?(&:closed?)
  ensure
    trace&.disable
    release << true if release
    if child
      begin
        unless Process.waitpid(child.last.pid, Process::WNOHANG)
          Process.kill("KILL", child.last.pid)
          Process.waitpid(child.last.pid)
        end
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
    end
    begin
      fixture&.close
    rescue LibTmuxTest::TmuxFixture::Error
      nil
    end
  end

  def test_exit_observation_keeps_the_server_pid_owned_until_cleanup
    pid = nil
    LibTmuxTest::TmuxFixture.open do |fixture|
      server = fixture.instance_variable_get(:@server).last
      pid = server.pid
      assert fixture.tmux("kill-server").last.success?
      assert server.join(0.5), "server exit was not observed"
      LibTmux::Internal::ProcessWait.new.observe(pid)
    end

    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  def test_isolates_servers_and_clears_inherited_tmux_environment
    inherited = ENV.values_at("TMUX", "TMUX_PANE")
    ENV["TMUX"] = "/unowned/socket,123,0"
    ENV["TMUX_PANE"] = "%999"
    directories = []
    server_pids = []

    LibTmuxTest::TmuxFixture.open do |outer|
      directories << File.dirname(outer.socket_path)
      server_pids << server_pid(outer)
      LibTmuxTest::TmuxFixture.open do |inner|
        directories << File.dirname(inner.socket_path)
        server_pids << server_pid(inner)
        refute_equal outer.socket_path, inner.socket_path
        assert File.basename(directories.last).start_with?("libtmux-ruby-")
        assert inner.tmux("rename-session", "-t", "fixture", "inner").last.success?
        assert_equal "fixture\n", outer.tmux("list-sessions", "-F", '#{session_name}').first
        assert_equal "inner\n", inner.tmux("list-sessions", "-F", '#{session_name}').first
        %w[TMUX TMUX_PANE].each do |name|
          output, error, status = inner.tmux("show-environment", "-g", name)
          refute status.success?, "inherited #{name} reached the owned server"
          assert_empty output
          assert_equal Encoding::BINARY, error.encoding
        end
      end
      refute File.exist?(directories.last)
      assert outer.tmux("has-session", "-t", "fixture").last.success?
    end

    directories.each { |path| refute File.exist?(path) }
    server_pids.each { |pid| assert_raises(Errno::ESRCH) { Process.kill(0, pid) } }
  ensure
    ENV["TMUX"], ENV["TMUX_PANE"] = inherited
  end

  def test_preserves_block_exception_and_reaps_owned_server
    directory = pid = nil
    failure = RuntimeError.new("fixture body failed")

    assert_same failure, assert_raises(RuntimeError) {
      LibTmuxTest::TmuxFixture.open do |fixture|
        directory = File.dirname(fixture.socket_path)
        pid = server_pid(fixture)
        parent = File.read("/proc/#{pid}/status")[/^PPid:\s+(\d+)/, 1].to_i
        assert_equal Process.pid, parent, "fixture server must remain an owned child"
        raise failure
      end
    }

    refute File.exist?(directory)
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  def test_cancellation_retires_a_dispatched_client_and_its_server
    started = Queue.new
    worker = Thread.new do
      Thread.current.report_on_exception = false
      begin
        LibTmuxTest::TmuxFixture.open do |fixture|
          started << [fixture, server_pid(fixture)]
          fixture.tmux("wait-for", "-S", "dispatched", ";", "wait-for", "unreleased")
        end
      rescue Exception => error
        started << error
        raise
      end
    end
    startup = started.pop
    raise startup if startup.is_a?(Exception)

    fixture, pid = startup
    assert fixture.tmux("wait-for", "dispatched").last.success?
    children = File.read("/proc/self/task/#{worker.native_thread_id}/children").split.map(&:to_i)
    clients = children - [pid]
    assert_equal 1, clients.length, "expected one dispatched child client"
    worker.raise(Interrupt, "cancel fixture")
    assert_raises(Interrupt) { worker.join(0.5) }
    refute worker.alive?, "cancellation did not finish owned cleanup"
    refute File.exist?(File.dirname(fixture.socket_path))
    [pid, *clients].each do |owned_pid|
      assert_raises(Errno::ESRCH) { Process.kill(0, owned_pid) }
      assert_raises(Errno::ECHILD) { Process.waitpid(owned_pid, Process::WNOHANG) }
    end
  ensure
    if worker&.alive?
      worker.kill
      worker.join(0.5)
    end
  end

  def test_cleanup_does_not_follow_a_replaced_socket_to_another_server
    owned_pid = nil
    LibTmuxTest::TmuxFixture.open do |other|
      other_pid = server_pid(other)
      LibTmuxTest::TmuxFixture.open do |owned|
        owned_pid = server_pid(owned)
        File.rename(owned.socket_path, "#{owned.socket_path}.moved")
        File.symlink(other.socket_path, owned.socket_path)
      end

      assert other.tmux("has-session", "-t", "fixture").last.success?
      assert_equal other_pid, server_pid(other)
      assert_raises(Errno::ESRCH) { Process.kill(0, owned_pid) }
    end
  end

  def test_retirement_failure_does_not_skip_other_owned_resources
    fixture = nil
    resources = []
    error = assert_raises(LibTmuxTest::TmuxFixture::Error) do
      LibTmuxTest::TmuxFixture.open do |owned|
        fixture = owned
        2.times do |index|
          client = owned.send(:spawn_owned, "tmux",
            "-N", "-S", owned.socket_path, "wait-for", "-S", "client-#{index}",
            ";", "wait-for", "unreleased")
          client.first.close
          resources << client
          owned.instance_variable_get(:@clients)[client.last.pid] = client
          assert owned.tmux("wait-for", "client-#{index}").last.success?
        end
        resources << owned.instance_variable_get(:@server)
        owned.define_singleton_method(:retire) do |process|
          super(process)
          raise IOError, "private cleanup detail" if process.equal?(resources.first)
        end
      end
    end

    assert_equal 1, error.cleanup_errors.length
    assert_includes error.cleanup_errors.first, "IOError"
    refute_includes error.cleanup_errors.first, "private cleanup detail"
    resources.each do |resource|
      assert resource[0...-1].all?(&:closed?), "retirement failure left owned pipes open"
      assert_raises(Errno::ECHILD) { Process.waitpid(resource.last.pid, Process::WNOHANG) }
    end
    refute File.exist?(File.dirname(fixture.socket_path))
  ensure
    resources.each do |resource|
      LibTmuxTest::TmuxFixture.instance_method(:retire).bind_call(fixture, resource)
    end
    directory = File.dirname(fixture.socket_path) if fixture
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end

  def test_block_failure_survives_cleanup_failure_with_diagnostics
    fixture = nil
    failure = RuntimeError.new("original block failure")
    error = assert_raises(RuntimeError) do
      LibTmuxTest::TmuxFixture.open do |owned|
        fixture = owned
        owned.define_singleton_method(:retire) do |process|
          super(process)
          raise IOError, "retirement failed"
        end
        raise failure
      end
    end

    assert_same failure, error
    assert_equal 1, error.fixture_cleanup_errors.length
    assert_includes error.fixture_cleanup_errors.first, "IOError"
    refute File.exist?(File.dirname(fixture.socket_path))
  ensure
    directory = File.dirname(fixture.socket_path) if fixture
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end

  def test_repeated_interruption_during_cleanup_preserves_first_failure
    ready = Queue.new
    cleaning = Queue.new
    release = Queue.new
    failure = Interrupt.new("first cancellation")
    worker = Thread.new do
      Thread.current.report_on_exception = false
      begin
        LibTmuxTest::TmuxFixture.open do |owned|
          ready << owned
          owned.define_singleton_method(:retire) do |process|
            cleaning << true
            release.pop
            super(process)
          end
          Queue.new.pop
        end
      rescue Exception => error
        error
      end
    end
    fixture = ready.pop(timeout: 0.5)
    assert fixture, "fixture did not reach its interruption barrier"
    worker.raise(failure)
    assert cleaning.pop(timeout: 0.5), "fixture did not begin owned cleanup"
    worker.raise(Interrupt, "second cancellation")
    release << true
    assert worker.join(0.5), "repeated interruption prevented fixture cleanup"
    assert_same failure, worker.value
    refute File.exist?(File.dirname(fixture.socket_path))
  ensure
    release << true if release
    worker&.kill if worker&.alive?
    worker&.join(0.5)
  end

  private

  def server_pid(fixture)
    output, error, status = fixture.tmux("display-message", "-p", '#{pid}')
    assert status.success?, error
    Integer(output, 10)
  end
end
