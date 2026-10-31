# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"
require "open3"

# Each case first requires the sandbox to hold, so a broken one fails before
# any client runs. The clients here name no socket; the sandbox is what
# decides where they look, and nothing listens there.
class SandboxCanaryTest < Minitest::Test
  EXECUTABLE = ENV.fetch("LIBTMUX_TEST_TMUX", "tmux")

  def test_a_client_that_names_no_socket_looks_only_in_the_sandbox
    require_sandbox
    output, status = Open3.capture2e(EXECUTABLE, "-N", "-f", "/dev/null", "list-sessions")
    refute_predicate status, :success?
    assert_includes output, default_socket
  end

  def test_the_resolver_looks_where_a_client_looks
    require_sandbox
    assert_equal default_socket, LibTmux::Endpoint.new(socket_name: "default", executable: EXECUTABLE).socket_path
    assert_equal default_socket, LibTmux::Endpoint.from_env(ENV, executable: EXECUTABLE).socket_path
  end

  def test_the_resolver_check_can_fail_because_the_default_moves_with_tmux_tmpdir
    require_sandbox
    path = without_tmux_tmpdir { LibTmux::Endpoint.new(socket_name: "default", executable: EXECUTABLE).socket_path }
    assert_equal "/tmp/tmux-#{Process.uid}/default", path
    refute_equal default_socket, path
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
