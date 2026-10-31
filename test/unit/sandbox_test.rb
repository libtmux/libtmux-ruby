# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/sandbox"
require "fileutils"
require "open3"
require "tmpdir"

# Nothing here starts tmux. Children run a recording script named tmux that
# writes its argv to a file and exits. It records which selectors are set and
# where TMUX_TMPDIR points by name and class, never by value, because a failed
# assertion prints the log and the child inherits the developer's environment.
class SandboxTest < Minitest::Test
  Sandbox = LibTmuxTest::Sandbox
  DECOYS = {"TMUX" => "/decoy/server,1,0", "TMUX_PANE" => "%9", "LIBTMUX_SOCKET" => "decoy-name",
            "LIBTMUX_SOCKET_PATH" => "/decoy/path", "LIBTMUX_SOCKET_NAME" => "decoy-other"}.freeze
  TESTS = File.expand_path("..", __dir__)
  RECORDER = <<~'SH'
    #!/bin/sh
    {
      echo CALL
      for argument in "$@"; do echo "ARG $argument"; done
      env | sed -n -E 's/^(TMUX|TMUX_PANE|LIBTMUX_SOCKET[A-Z_]*)=.*/SET \1/p'
      case "$TMUX_TMPDIR" in
        "") echo "TMUX_TMPDIR unset" ;;
        */lt-rb-*) echo "TMUX_TMPDIR sandbox" ;;
        /decoy/tmpdir) echo "TMUX_TMPDIR decoy" ;;
        *) echo "TMUX_TMPDIR other" ;;
      esac
    } >> "$FAKE_TMUX_LOG"
    if [ -n "$FAKE_TMUX_KILLS" ] && [ "$1" = -S ] && [ "$3" = kill-server ]; then rm -f -- "${2:?}"; fi
    exit 1
  SH

  def test_this_process_is_sandboxed
    assert_empty Sandbox.violations(ENV)
    assert ENV.fetch("TMUX_TMPDIR") == ENV.fetch(Sandbox::MARKER), "TMUX_TMPDIR is not the marked sandbox"
  end

  def test_every_selector_is_named_without_its_value
    found = Sandbox.violations(DECOYS)
    DECOYS.each_key { |name| assert_includes found, "#{name} is set" }
    refute_match(/decoy|server/, found.join)
    error = assert_raises(Sandbox::Refused) { Sandbox.check!(DECOYS) }
    assert_includes error.message, "TMUX is set"
    refute_match(/decoy|server/, error.message)
  end

  def test_unrelated_variables_and_unset_selectors_stay_quiet
    env = ENV.to_h.merge("LIBTMUX_TEST_TMUX" => "tmux", "LIBTMUX_RELEASE_DIR" => "pkg", "TMUX_VERSION" => "3.8",
      "TMUX" => nil, "LIBTMUX_SOCKET" => nil)
    assert_empty Sandbox.violations(env)
  end

  def test_tmux_tmpdir_must_be_the_sandbox_of_this_run
    directory = ENV.fetch("TMUX_TMPDIR")
    marked = ->(path) { ENV.to_h.merge("TMUX_TMPDIR" => path, Sandbox::MARKER => path) }
    [["is unset", ENV.to_h.merge("TMUX_TMPDIR" => nil)],
     ["is not an absolute path", marked.call("relative/lt-rb-x")],
     ["is longer than", marked.call(File.join(directory, "x" * Sandbox::MAX_BYTES))],
     ["is not the sandbox directory of this run", ENV.to_h.merge("TMUX_TMPDIR" => "/tmp")],
     ["is not the sandbox directory of this run", ENV.to_h.merge(Sandbox::MARKER => nil)],
     ["missing", marked.call("#{directory}x")]].each do |expected, env|
      found = Sandbox.violations(env)
      assert_equal 1, found.length, expected
      assert_includes found.first, expected
    end
  end

  def test_prepare_clears_selectors_and_makes_a_short_private_directory
    env = DECOYS.merge("TMUX_TMPDIR" => "/decoy/tmpdir", "LIBTMUX_RELEASE_DIR" => "kept")
    directory, created = Sandbox.prepare(env)
    assert created
    assert_empty Sandbox.violations(env)
    assert_equal({"TMUX_TMPDIR" => directory, Sandbox::MARKER => directory, "LIBTMUX_RELEASE_DIR" => "kept"}, env)
    assert_operator directory.bytesize, :<=, Sandbox::MAX_BYTES
    assert_equal 0o700, File.stat(directory).mode & 0o777
    refute directory == ENV.fetch("TMUX_TMPDIR"), "made no directory of its own"
  ensure
    assert_predicate Sandbox.release(directory), :clean? if directory
    refute File.exist?(directory) if directory
  end

  def test_prepare_joins_the_sandbox_a_parent_entered
    env = ENV.to_h.merge("TMUX" => "/decoy/server,1,0")
    directory, created = Sandbox.prepare(env)
    refute created
    assert directory == ENV.fetch("TMUX_TMPDIR"), "joined another directory"
    refute env.key?("TMUX")
  end

  def test_prepare_refuses_without_a_directory_short_enough_for_a_socket
    [["/" + "x" * Sandbox::MAX_BYTES], ["/libtmux-ruby-missing"]].each do |roots|
      env = {}
      assert_raises(Sandbox::Refused) { Sandbox.prepare(env, roots: roots) }
      assert_empty env
    end
  end

  def test_a_leak_is_a_socket_anywhere_in_the_tree_whoever_named_it
    Dir.mktmpdir("libtmux-ruby-sandbox-") do |directory|
      assert_empty Sandbox.leaks(directory)
      FileUtils.mkdir_p(File.join(directory, "tmux-1000"))
      File.write(File.join(directory, "tmux-1000", "not-a-socket"), "")
      assert_empty Sandbox.leaks(directory)
      listen(directory, "tmux-1000", "default")
      listen(directory, "custom.sock")
      listen(directory, ".hidden", "deep", "s")
      assert_equal %w[.hidden/deep/s custom.sock tmux-1000/default], Sandbox.leaks(directory)
    end
  end

  def test_a_link_to_a_socket_elsewhere_is_not_a_leak_and_is_not_stopped
    with_directories do |directory, bin|
      elsewhere = listen(bin, "outside.sock")
      File.symlink(elsewhere, File.join(directory, "link.sock"))
      log = File.join(bin, "calls")
      released = Sandbox.release(directory, tmux: fake_tmux(bin, "echo called >> '#{log}'"), wait: 1)
      assert_empty released.leaked
      refute File.exist?(log)
      refute File.exist?(directory)
    end
  end

  def test_release_stops_each_server_wherever_it_sits_and_removes_the_directory
    with_directories do |directory, bin|
      sockets = [%w[tmux-1000 default], %w[custom.sock], %w[a b c.sock]].map { |path| listen(directory, *path) }
      log = File.join(bin, "calls")
      kill = fake_tmux(bin, "echo \"$3 $2\" >> '#{log}'; rm -f -- \"${2:?}\"")
      released = Sandbox.release(directory, tmux: kill, wait: 1)
      assert_equal %w[a/b/c.sock custom.sock tmux-1000/default], released.leaked
      assert_empty released.answering
      assert_equal sockets.sort.map { |socket| "kill-server #{socket}" }, File.read(log).lines.map(&:chomp).sort
      refute File.exist?(directory)
    end
  end

  def test_release_waits_for_a_server_that_takes_a_moment_to_go
    with_directories do |directory, bin|
      listen(directory, "custom.sock")
      slow = fake_tmux(bin, "(sleep 0.4; rm -f -- \"${2:?}\") &")
      released = Sandbox.release(directory, tmux: slow, wait: 5)
      assert_empty released.answering
      refute File.exist?(directory)
    end
  end

  def test_release_keeps_the_directory_while_a_server_still_answers
    with_directories do |directory, bin|
      listen(directory, "custom.sock")
      listen(directory, "gone.sock")
      one = fake_tmux(bin, "case \"$2\" in */gone.sock) rm -f -- \"${2:?}\" ;; esac")
      released = Sandbox.release(directory, tmux: one, wait: 0.2)
      assert_equal %w[custom.sock gone.sock], released.leaked
      assert_equal %w[custom.sock], released.answering
      assert File.exist?(File.join(directory, "custom.sock")), "removed the directory of a live server"
      message = released.message(directory)
      assert_includes message, "custom.sock"
      assert_includes message, "#{File.basename(directory)} was kept"
      refute_includes message, File.dirname(directory)
    end
  end

  def test_the_stop_hands_tmux_no_selector_and_keeps_tmux_tmpdir
    with_directories do |directory, bin|
      listen(directory, "custom.sock")
      log = File.join(bin, "calls")
      names = "TMUX|TMUX_PANE|TMUX_TMPDIR|LIBTMUX_SOCKET[A-Z_]*"
      recorder = fake_tmux(bin, "env | sed -n -E 's/^(#{names})=.*/\\1/p' >> '#{log}'; rm -f -- \"${2:?}\"")
      saved = DECOYS.keys.to_h { |name| [name, ENV.fetch(name, nil)] }
      begin
        DECOYS.each { |name, value| ENV[name] = value }
        Sandbox.release(directory, tmux: recorder, wait: 1)
      ensure
        saved.each { |name, value| ENV[name] = value }
      end
      assert_equal ["TMUX_TMPDIR"], File.read(log).lines.map(&:chomp)
    end
  end

  def test_release_keeps_the_directory_when_there_is_no_tmux_to_stop_the_server
    with_directories do |directory, bin|
      listen(directory, "custom.sock")
      released = Sandbox.release(directory, tmux: File.join(bin, "missing-tmux"), wait: 0.2)
      assert_equal %w[custom.sock], released.answering
      assert File.exist?(directory)
    end
  end

  def test_the_overlay_unsets_what_a_saved_environment_may_carry
    overlay = Sandbox.overlay(DECOYS.merge("PATH" => "/bin"))
    DECOYS.each_key { |name| assert overlay.key?(name) && overlay[name].nil?, name }
    assert ENV.fetch("TMUX_TMPDIR") == overlay.fetch("TMUX_TMPDIR"), "overlay names another TMUX_TMPDIR"
    assert ENV.fetch(Sandbox::MARKER) == overlay.fetch(Sandbox::MARKER), "overlay names another marker"
    refute overlay.key?("PATH")
    assert_equal Sandbox::NAMES.sort, Sandbox.overlay({}).select { |_, value| value.nil? }.keys.sort
  end

  def test_a_child_that_loads_the_sandbox_hands_tmux_none_of_the_selectors
    with_recorder do |recorder, run|
      run.call(true, "system('tmux', 'list-sessions')")
      calls = File.read(recorder)
      assert_equal ["ARG list-sessions"], calls.lines.map(&:chomp).grep(/\AARG /)
      DECOYS.each_key { |name| refute_includes calls, "SET #{name}\n" }
      assert_includes calls, "TMUX_TMPDIR sandbox\n"
    end
  end

  def test_the_same_child_without_the_sandbox_hands_tmux_every_selector
    with_recorder do |recorder, run|
      run.call(false, "system('tmux', 'list-sessions')")
      calls = File.read(recorder)
      DECOYS.each_key { |name| assert_includes calls, "SET #{name}\n" }
      assert_includes calls, "TMUX_TMPDIR decoy\n"
    end
  end

  def test_a_run_that_leaves_a_socket_in_the_sandbox_fails_and_stops_that_server
    code = 'require "socket"; require "fileutils"; socket = File.join(ENV.fetch("TMUX_TMPDIR"), *ARGV); ' \
      'FileUtils.mkdir_p(File.dirname(socket)); UNIXServer.new(socket); puts ENV.fetch("TMUX_TMPDIR")'
    [["tmux-#{Process.uid}", "default"], ["custom.sock"]].each do |path|
      with_recorder("FAKE_TMUX_KILLS" => "1") do |recorder, run|
        output, error, status = run.call(true, code, *path)
        sandbox = output.chomp
        assert_equal 1, status.exitstatus, path.join("/")
        assert_includes error, path.join("/")
        refute_includes error, "answers"
        assert_equal ["ARG -S", "ARG #{sandbox}/#{path.join('/')}", "ARG kill-server"],
          File.read(recorder).lines.map(&:chomp).grep(/\AARG /)
        refute File.exist?(sandbox)
      end
    end
  end

  def test_a_run_whose_server_survives_kill_server_keeps_the_sandbox_and_says_so
    code = 'require "socket"; UNIXServer.new(File.join(ENV.fetch("TMUX_TMPDIR"), "custom.sock")); puts ENV.fetch("TMUX_TMPDIR")'
    with_recorder do |_recorder, run|
      output, error, status = run.call(true, code)
      sandbox = output.chomp
      begin
        assert_equal 1, status.exitstatus
        assert_includes error, "a server still answers at custom.sock"
        assert_includes error, "#{File.basename(sandbox)} was kept"
        refute_includes error, File.dirname(sandbox)
        assert File.directory?(sandbox), "removed the directory of a server that was not stopped"
      ensure
        FileUtils.rm_rf(sandbox) if sandbox.include?("/lt-rb-")
      end
    end
  end

  def test_the_canary_failure_does_not_echo_what_tmux_printed
    canary = File.join(TESTS, "integration", "sandbox_test.rb")
    Dir.mktmpdir("libtmux-ruby-sandbox-") do |directory|
      printer = fake_tmux(directory, "echo 'error connecting to /lt-rb-echo-decoy/socket (No such file or directory)'; exit 1")
      output, error, status = Open3.capture3({"LIBTMUX_TEST_TMUX" => printer}, Gem.ruby, "-I#{TESTS}", canary, "-n",
        "test_a_client_that_names_no_socket_looks_only_in_the_sandbox")
      refute_predicate status, :success?, "the canary accepted a client that looked elsewhere"
      assert_includes output, "the client looked outside the sandbox"
      refute_includes output + error, "lt-rb-echo-decoy"
    end
  end

  def test_a_run_that_leaves_nothing_exits_clean_and_removes_its_directory
    with_recorder do |recorder, run|
      output, error, status = run.call(true, 'puts ENV.fetch("TMUX_TMPDIR")')
      assert_predicate status, :success?
      assert_empty error
      refute File.exist?(output.chomp)
      refute File.exist?(recorder)
    end
  end

  def test_the_runner_enters_the_sandbox_before_it_starts_a_suite
    Dir.mktmpdir("libtmux-ruby-sandbox-") do |directory|
      probe = File.join(directory, "probe_test.rb")
      File.write(probe, <<~RUBY)
        require "minitest/autorun"
        class ProbeTest < Minitest::Test
          def test_selectors_are_gone_and_tmux_tmpdir_is_a_sandbox
            names = ENV.keys.select { |name| %w[TMUX TMUX_PANE].include?(name) || name.start_with?("LIBTMUX_SOCKET") }
            assert_empty names
            assert ENV.fetch("TMUX_TMPDIR").include?("/lt-rb-"), "TMUX_TMPDIR is not an lt-rb- directory"
          end
        end
      RUBY
      env = DECOYS.merge("TMUX_TMPDIR" => "/decoy/tmpdir", Sandbox::MARKER => nil)
      _, error, status = Open3.capture3(env, Gem.ruby, File.expand_path("../../scripts/check", __dir__), "unit", probe)
      assert_predicate status, :success?, error
      _, _, status = Open3.capture3(env, Gem.ruby, probe)
      refute_predicate status, :success?
    end
  end

  private

  # Yields a directory named like a sandbox and a second one for scripts and
  # sockets outside it, and removes both.
  def with_directories
    Dir.mktmpdir("libtmux-ruby-sandbox-") do |bin|
      directory = Dir.mktmpdir(Sandbox::PREFIX)
      begin
        yield directory, bin
      ensure
        FileUtils.rm_rf(directory) if File.basename(directory).start_with?(Sandbox::PREFIX)
      end
    end
  end

  def fake_tmux(directory, body)
    path = File.join(directory, "tmux")
    File.write(path, "#!/bin/sh\n#{body}\n", perm: 0o755)
    path
  end

  # A socket with a server listening on it until the test ends.
  def listen(directory, *path)
    full = File.join(directory, *path)
    FileUtils.mkdir_p(File.dirname(full))
    (@servers ||= []) << UNIXServer.new(full)
    full
  end

  def teardown
    @servers&.each(&:close)
  end

  # Yields the recorder's log path and a runner for a child Ruby whose
  # environment holds the decoys and whose PATH finds only the recorder.
  def with_recorder(extra = {})
    Dir.mktmpdir("libtmux-ruby-sandbox-") do |directory|
      bin = File.join(directory, "bin")
      Dir.mkdir(bin)
      File.write(File.join(bin, "tmux"), RECORDER, perm: 0o755)
      log = File.join(directory, "calls")
      env = DECOYS.merge("TMUX_TMPDIR" => "/decoy/tmpdir", Sandbox::MARKER => nil, "FAKE_TMUX_LOG" => log,
        "PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}", "LIBTMUX_TEST_TMUX" => "tmux").merge(extra)
      run = lambda do |preload, code, *arguments|
        preloads = preload ? ["-rsupport/sandbox"] : []
        Open3.capture3(env, Gem.ruby, "-I#{TESTS}", *preloads, "-e", code, *arguments)
      end
      yield log, run
    end
  end
end
