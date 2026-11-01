# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "fileutils"
require "libtmux"
require "open3"
require "tmpdir"

# Binds a server with no socket argument, so the socket comes from the
# environment the test hands the endpoint. Every server is private: the
# fixture's own socket, or one that tmux places under a throwaway TMUX_TMPDIR.
class DefaultSocketTest < Minitest::Test
  EXECUTABLE = ENV.fetch("LIBTMUX_TEST_TMUX", "tmux")

  def test_the_path_variable_binds_the_server_at_that_path
    LibTmuxTest::TmuxFixture.open do |fixture|
      assert_equal ["fixture"], sessions(environment: {"LIBTMUX_SOCKET_PATH" => fixture.socket_path})
    end
  end

  def test_the_name_variable_binds_the_named_server_in_the_tmux_directory
    with_private_tmux_directory do |directory|
      start_tmux(directory, "-L", "named", session: "named")
      assert_equal ["named"], sessions(environment: {"LIBTMUX_SOCKET" => "named", "TMUX_TMPDIR" => directory})
    end
  end

  def test_the_path_variable_wins_over_the_name_variable
    LibTmuxTest::TmuxFixture.open do |fixture|
      with_private_tmux_directory do |directory|
        start_tmux(directory, "-L", "named", session: "named")
        variables = {"LIBTMUX_SOCKET_PATH" => fixture.socket_path, "LIBTMUX_SOCKET" => "named", "TMUX_TMPDIR" => directory}
        assert_equal ["fixture"], sessions(environment: variables)
      end
    end
  end

  def test_with_nothing_set_it_binds_the_default_server_of_the_tmux_directory
    with_private_tmux_directory do |directory|
      start_tmux(directory, session: "bare")
      assert_equal ["bare"], sessions(environment: {"TMUX_TMPDIR" => directory})
    end
  end

  def test_with_nothing_set_and_no_server_it_refuses_instead_of_starting_one
    with_private_tmux_directory do |directory|
      error = assert_raises(LibTmux::TargetNotFoundError) { sessions(environment: {"TMUX_TMPDIR" => directory}) }
      assert_includes error.message, "endpoint is unavailable"
      assert_empty Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).select { |path| File.socket?(path) }
    end
  end

  def test_inside_tmux_it_binds_the_server_tmux_names_and_not_the_default
    LibTmuxTest::TmuxFixture.open do |fixture|
      with_private_tmux_directory do |directory|
        start_tmux(directory, session: "bare")
        inside = {"TMUX" => "#{fixture.socket_path},4321,0", "TMUX_TMPDIR" => directory}
        assert_equal ["fixture"], sessions(environment: inside)
        assert_equal ["bare"], sessions(environment: inside.merge("TMUX" => nil))
      end
    end
  end

  def test_a_variable_wins_over_the_tmux_server
    LibTmuxTest::TmuxFixture.open do |fixture|
      with_private_tmux_directory do |directory|
        start_tmux(directory, "-L", "named", session: "named")
        inside = {"TMUX" => "#{fixture.socket_path},4321,0", "TMUX_TMPDIR" => directory}
        assert_equal ["named"], sessions(environment: inside.merge("LIBTMUX_SOCKET" => "named"))
      end
    end
  end

  private

  # An environment that names no tmux directory gets an empty one, so a rule
  # that fails to pick the expected socket finds no server instead of the
  # default server of whoever runs the suite.
  def sessions(environment:)
    Dir.mktmpdir("libtmux-ruby-empty-") do |empty|
      endpoint = LibTmux::Endpoint.new(executable: EXECUTABLE, environment: {"TMUX_TMPDIR" => empty}.merge(environment).compact)
      LibTmux::Server.open(endpoint: endpoint) do |server|
        server.run(["list-sessions", "-F", '#{session_name}']).text.lines.map(&:chomp)
      end
    end
  end

  # A directory short enough for a socket path. tmux puts its sockets in it.
  def with_private_tmux_directory
    directory = Dir.mktmpdir("libtmux-ruby-default-")
    yield directory
  ensure
    if directory
      Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).select { |path| File.socket?(path) }.each do |socket|
        Open3.capture3(EXECUTABLE, "-S", socket, "kill-server")
      end
      FileUtils.remove_entry(directory)
    end
  end

  def start_tmux(directory, *selector, session:)
    environment = {"TMUX_TMPDIR" => directory, "TMUX" => nil, "TMUX_PANE" => nil,
      "LIBTMUX_SOCKET" => nil, "LIBTMUX_SOCKET_PATH" => nil}
    _, error, status = Open3.capture3(environment, EXECUTABLE, *selector, "-f", "/dev/null",
      "new-session", "-d", "-s", session, "cat")
    assert status.success?, "tmux could not start the #{session} server: #{error}"
  end
end
