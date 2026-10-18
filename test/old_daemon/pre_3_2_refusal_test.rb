# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"
require "libtmux/mcp/cli"
require "fileutils"
require "stringio"
require "tmpdir"

# Runs in the compatibility lanes that build tmux 3.0a and 3.1c. LIBTMUX_TEST_TMUX
# names the old daemon's executable, LIBTMUX_VERSION_CHECK_CLIENT_TMUX a client
# of tmux 3.3a or newer, and LIBTMUX_VERSION_CHECK_EXPECT the release under test.
# A 3.1 daemon answers the probe with run-shell usage, a 3.0 daemon makes the
# client report that the server is too old, and both keep the client's stdout
# pipe open after the client exits, so the refusal has to return without it.
# The old executable is never the client: it rejects -N.
class Pre32RefusalTest < Minitest::Test
  DAEMON = ENV.fetch("LIBTMUX_TEST_TMUX")
  CLIENT = ENV.fetch("LIBTMUX_VERSION_CHECK_CLIENT_TMUX")
  EXPECT = ENV.fetch("LIBTMUX_VERSION_CHECK_EXPECT")
  PROMPT_SECONDS = 2.0

  def test_the_lane_runs_the_release_it_names
    assert_includes %w[3.0a 3.1c], EXPECT
    assert_equal "tmux #{EXPECT}", capture(DAEMON, "-V").strip
    refute_equal DAEMON, CLIENT
    release = LibTmux::Internal::TmuxVersion.parse(capture(CLIENT, "-V").strip.delete_prefix("tmux "))
    assert_operator release, :>=, LibTmux::Internal::TmuxVersion.parse("3.3a")
  end

  def test_the_old_daemon_is_refused_before_effects_without_waiting_for_its_stdout
    with_daemon do |socket|
      started = monotonic
      error = assert_raises(LibTmux::UnsupportedFeatureError) { LibTmux::Server.open(socket_path: socket, executable: CLIENT) }
      assert_operator monotonic - started, :<, PROMPT_SECONDS
      assert_equal [:not_sent, :admission], [error.delivery, error.phase]
      assert_match(/tmux 3\.3a or newer is required \(the connected daemon is older than 3\.2\); upgrade tmux and restart the server/,
        error.message)
      assert_untouched(socket)
    end
  end

  def test_the_mcp_entry_point_reports_the_refusal_promptly
    with_daemon do |socket|
      input, closed = IO.pipe
      closed.close
      output, protocol = IO.pipe
      errors = StringIO.new
      started = monotonic
      status = LibTmux::MCP::CLI.run(["--socket", socket, "--tmux", CLIENT], input: input, out: protocol, err: errors)
      elapsed = monotonic - started
      protocol.close
      assert_equal 1, status
      assert_empty output.read
      assert_operator elapsed, :<, PROMPT_SECONDS
      assert_match(/MCP refused to start: tmux 3\.3a or newer is required/, errors.string)
      assert_untouched(socket)
    end
  end

  def test_owned_startup_refuses_the_old_executable_before_a_daemon_starts
    error = assert_raises(LibTmux::UnsupportedFeatureError) { LibTmux::Server.start(executable: DAEMON) }
    assert_equal :not_sent, error.delivery
    assert_match(/the executable reports #{Regexp.escape(EXPECT)}/, error.message)
  end

  private

  # The daemon forks away from its first client, which keeps the pipes open, so
  # the fixture sends every descriptor to files and never reads a pipe.
  def with_daemon
    Dir.mktmpdir("libtmux-ruby-pre-3-2-") do |directory|
      socket = File.join(directory, "socket")
      config = File.join(directory, "tmux.conf")
      File.write(config, "set-option -g default-shell /bin/sh\n")
      environment = {"TMUX" => nil, "TMUX_PANE" => nil}
      streams = {in: File::NULL, out: File.join(directory, "out"), err: File.join(directory, "err")}
      pid = nil
      begin
        Process.wait(Process.spawn(environment, DAEMON, "-S", socket, "-f", config, "new-session", "-d", "-s", "fixture", "cat", **streams))
        wait_for_socket(socket)
        pid = capture(DAEMON, "-S", socket, "display-message", "-p", '#{pid}').to_i
        assert_equal EXPECT, capture(DAEMON, "-S", socket, "display-message", "-p", '#{version}').strip
        assert_equal "", old(socket, "set-option", "-g", "@sentinel", "planted")
        yield socket
      ensure
        Process.kill("TERM", pid) if pid&.positive?
      end
    end
  end

  def assert_untouched(socket)
    assert_equal "planted", old(socket, "show-option", "-gqv", "@sentinel").strip
    assert_equal "fixture", old(socket, "list-sessions", "-F", '#{session_name}').strip
  end

  def old(socket, *arguments)
    capture(DAEMON, "-S", socket, *arguments)
  end

  def capture(*command)
    Dir.mktmpdir("libtmux-ruby-capture-") do |directory|
      out = File.join(directory, "out")
      Process.wait(Process.spawn({"TMUX" => nil, "TMUX_PANE" => nil}, *command, in: File::NULL, out: out, err: File::NULL))
      File.read(out)
    end
  end

  def wait_for_socket(path)
    deadline = monotonic + 5
    sleep 0.01 until File.socket?(path) || monotonic > deadline
    assert File.socket?(path), "the old daemon did not create its socket"
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
