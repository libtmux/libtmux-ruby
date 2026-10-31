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
    assert_empty Sandbox.release(directory) if directory
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

  def test_a_leak_is_a_socket_tmux_chose_under_the_sandbox
    Dir.mktmpdir("libtmux-ruby-sandbox-") do |directory|
      assert_empty Sandbox.leaks(directory)
      FileUtils.mkdir_p(File.join(directory, "tmux-1000"))
      assert_empty Sandbox.leaks(directory)
      File.write(File.join(directory, "tmux-1000", "default"), "")
      assert_equal ["tmux-1000/default"], Sandbox.leaks(directory)
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
    code = 'require "socket"; directory = File.join(ENV.fetch("TMUX_TMPDIR"), "tmux-#{Process.uid}"); ' \
      'Dir.mkdir(directory); UNIXServer.new(File.join(directory, "default")); puts ENV.fetch("TMUX_TMPDIR")'
    with_recorder do |recorder, run|
      output, error, status = run.call(true, code)
      sandbox = output.chomp
      assert_equal 1, status.exitstatus
      assert_includes error, "tmux-#{Process.uid}/default"
      assert_equal ["ARG -S", "ARG #{sandbox}/tmux-#{Process.uid}/default", "ARG kill-server"],
        File.read(recorder).lines.map(&:chomp).grep(/\AARG /)
      refute File.exist?(sandbox)
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

  private

  # Yields the recorder's log path and a runner for a child Ruby whose
  # environment holds the decoys and whose PATH finds only the recorder.
  def with_recorder
    Dir.mktmpdir("libtmux-ruby-sandbox-") do |directory|
      bin = File.join(directory, "bin")
      Dir.mkdir(bin)
      File.write(File.join(bin, "tmux"), RECORDER, perm: 0o755)
      log = File.join(directory, "calls")
      env = DECOYS.merge("TMUX_TMPDIR" => "/decoy/tmpdir", Sandbox::MARKER => nil, "FAKE_TMUX_LOG" => log,
        "PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}", "LIBTMUX_TEST_TMUX" => "tmux")
      run = lambda do |preload, code|
        preloads = preload ? ["-rsupport/sandbox"] : []
        Open3.capture3(env, Gem.ruby, "-I#{TESTS}", *preloads, "-e", code)
      end
      yield log, run
    end
  end
end
