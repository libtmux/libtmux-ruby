# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"
require "open3"
require "tmpdir"

# Each case first requires the sandbox to hold, so a broken one fails before
# any client runs. The clients here name no socket; the sandbox is what
# decides where they look, and nothing listens there. The controls run the
# same client in a world that is not the sandbox and need the canary's own
# test to reject it. Failure messages are fixed text: what tmux prints names
# paths taken from the environment.
class SandboxCanaryTest < Minitest::Test
  EXECUTABLE = ENV.fetch("LIBTMUX_TEST_TMUX", "tmux")

  def test_a_client_that_names_no_socket_looks_only_in_the_sandbox
    require_sandbox
    output, status = bare_client
    refute_predicate status, :success?
    assert looks_in_the_sandbox?(output), "the client looked outside the sandbox"
  end

  def test_the_canary_rejects_a_client_whose_tmux_tmpdir_is_another_directory
    require_sandbox
    Dir.mktmpdir("libtmux-ruby-canary-", "/tmp") do |other|
      output, status = bare_client("TMUX_TMPDIR" => other)
      refute_predicate status, :success?
      refute looks_in_the_sandbox?(output)
      assert output.include?(File.join(other, "tmux-#{Process.uid}", "default")), "the client did not name the path it looked in"
    end
  end

  def test_the_canary_rejects_a_client_that_inherits_a_server
    require_sandbox
    output, status = bare_client("TMUX" => "/lt-rb-canary-decoy/socket,1,0")
    refute_predicate status, :success?
    refute looks_in_the_sandbox?(output)
    assert output.include?("/lt-rb-canary-decoy/socket"), "the client did not name the path it looked in"
  end

  def test_the_resolver_looks_where_a_client_looks
    require_sandbox
    named = LibTmux::Endpoint.new(socket_name: "default", executable: EXECUTABLE).socket_path
    assert named == default_socket, "Endpoint.new resolved the default outside the sandbox"
    inherited = LibTmux::Endpoint.from_env(ENV, executable: EXECUTABLE).socket_path
    assert inherited == default_socket, "Endpoint.from_env resolved the default outside the sandbox"
  end

  def test_the_resolver_check_can_fail_because_the_default_moves_with_tmux_tmpdir
    require_sandbox
    path = without_tmux_tmpdir { LibTmux::Endpoint.new(socket_name: "default", executable: EXECUTABLE).socket_path }
    assert path == "/tmp/tmux-#{Process.uid}/default", "the resolver did not fall back to /tmp without TMUX_TMPDIR"
    refute path == default_socket, "the resolver ignored the missing TMUX_TMPDIR"
  end

  def test_a_server_opened_on_the_default_name_finds_nothing
    require_sandbox
    endpoint = LibTmux::Endpoint.new(socket_name: "default", executable: EXECUTABLE)
    error = assert_raises(LibTmux::TargetNotFoundError) { LibTmux::Server.open(endpoint: endpoint) }
    assert_equal :bind, error.phase
  end

  private

  def require_sandbox
    assert_empty LibTmuxTest::Sandbox.violations(ENV), "refusing to start a client outside the sandbox"
  end

  def bare_client(env = {})
    Open3.capture2e(env, EXECUTABLE, "-N", "-f", "/dev/null", "list-sessions")
  end

  def looks_in_the_sandbox?(output)
    output.include?(default_socket)
  end

  def default_socket
    File.join(ENV.fetch("TMUX_TMPDIR"), "tmux-#{Process.uid}", "default")
  end

  def without_tmux_tmpdir
    saved = ENV.delete("TMUX_TMPDIR")
    yield
  ensure
    ENV["TMUX_TMPDIR"] = saved
  end
end
