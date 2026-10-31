# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../gems/libtmux/lib/libtmux/endpoint"

class EndpointTest < Minitest::Test
  TMUX_DIRECTORY = "/private-tmux-tmpdir"
  DEFAULT_DIRECTORY = "/tmp/tmux-#{Process.uid}"
  PRIVATE_DIRECTORY = "#{TMUX_DIRECTORY}/tmux-#{Process.uid}"

  def test_rejects_conflicting_and_malformed_selectors_but_requires_no_socket
    assert_raises(ArgumentError) do
      LibTmux::Endpoint.new(socket_path: "/unused", socket_name: "unused")
    end
    assert_raises(ArgumentError) { LibTmux::Endpoint.new(socket_directory: "/unused", environment: {}) }
    ["", "../escape", "a/b", "nul\0"].each do |name|
      assert_raises(ArgumentError) { LibTmux::Endpoint.new(socket_name: name) }
    end
    assert_raises(ArgumentError) { LibTmux::Endpoint.new(socket_path: "nul\0") }
    refute_nil endpoint({}).socket_path
  end

  def test_owns_configuration_and_does_not_follow_later_environment_changes
    path = +"/not-a-server/libtmux-ruby-socket"
    endpoint = LibTmux::Endpoint.new(socket_path: path)
    path.replace("/changed")
    assert_equal "/not-a-server/libtmux-ruby-socket", endpoint.socket_path
    assert endpoint.frozen?
    assert endpoint.socket_path.frozen?
    refute_includes endpoint.inspect, endpoint.socket_path
    assert File.executable?(endpoint.executable)
  end

  def test_ambient_selection_is_explicit_and_ignores_client_metadata
    endpoint = LibTmux::Endpoint.from_env({"TMUX" => "/chosen/socket,1234,0"})
    assert_equal "/chosen/socket", endpoint.socket_path
    named = LibTmux::Endpoint.new(socket_name: "named", socket_directory: "/explicit")
    assert_equal "/explicit/tmux-#{Process.uid}/named", named.socket_path
  end

  def test_the_path_variable_names_the_socket
    assert_equal "/chosen/path.sock", endpoint("LIBTMUX_SOCKET_PATH" => "/chosen/path.sock").socket_path
    assert_equal File.expand_path("relative.sock"), endpoint("LIBTMUX_SOCKET_PATH" => "relative.sock").socket_path
  end

  def test_the_name_variable_names_a_socket_in_the_tmux_directory
    assert_equal "#{PRIVATE_DIRECTORY}/named",
      endpoint("LIBTMUX_SOCKET" => "named", "TMUX_TMPDIR" => TMUX_DIRECTORY).socket_path
    assert_equal "#{DEFAULT_DIRECTORY}/named", endpoint("LIBTMUX_SOCKET" => "named").socket_path
  end

  def test_the_path_variable_wins_when_both_variables_are_set
    chosen = endpoint("LIBTMUX_SOCKET_PATH" => "/chosen/path.sock", "LIBTMUX_SOCKET" => "named")
    assert_equal "/chosen/path.sock", chosen.socket_path
  end

  def test_a_blank_variable_counts_as_unset
    assert_equal "#{DEFAULT_DIRECTORY}/named", endpoint("LIBTMUX_SOCKET_PATH" => "", "LIBTMUX_SOCKET" => "named").socket_path
    assert_equal "#{DEFAULT_DIRECTORY}/default", endpoint("LIBTMUX_SOCKET_PATH" => "", "LIBTMUX_SOCKET" => "").socket_path
    assert_equal "/inside/socket", endpoint("LIBTMUX_SOCKET" => "", "TMUX" => "/inside/socket,1,0").socket_path
    assert_equal "#{DEFAULT_DIRECTORY}/default", endpoint("TMUX_TMPDIR" => "").socket_path
  end

  def test_inside_tmux_the_socket_in_tmux_is_the_default
    assert_equal "/inside/socket", endpoint("TMUX" => "/inside/socket,4321,7", "TMUX_TMPDIR" => TMUX_DIRECTORY).socket_path
    assert_equal "/inside/socket", endpoint("TMUX" => "/inside/socket").socket_path
  end

  def test_a_tmux_value_without_a_socket_path_is_ignored_as_tmux_ignores_it
    [",4321,7", ""].each do |value|
      assert_equal "#{PRIVATE_DIRECTORY}/default", endpoint("TMUX" => value, "TMUX_TMPDIR" => TMUX_DIRECTORY).socket_path
    end
  end

  def test_with_nothing_set_the_default_socket_is_the_one_tmux_uses
    assert_equal "#{PRIVATE_DIRECTORY}/default", endpoint("TMUX_TMPDIR" => TMUX_DIRECTORY).socket_path
    assert_equal "#{DEFAULT_DIRECTORY}/default", endpoint.socket_path
  end

  def test_the_variables_win_over_the_tmux_socket
    assert_equal "/chosen/path.sock",
      endpoint("LIBTMUX_SOCKET_PATH" => "/chosen/path.sock", "TMUX" => "/inside/socket,1,0").socket_path
    assert_equal "#{DEFAULT_DIRECTORY}/named", endpoint("LIBTMUX_SOCKET" => "named", "TMUX" => "/inside/socket,1,0").socket_path
  end

  def test_an_explicit_socket_ignores_every_variable
    variables = {"LIBTMUX_SOCKET_PATH" => "/variable/path.sock", "LIBTMUX_SOCKET" => "variable",
      "TMUX" => "/inside/socket,1,0", "TMUX_TMPDIR" => TMUX_DIRECTORY}
    assert_equal "/explicit/path.sock", LibTmux::Endpoint.new(socket_path: "/explicit/path.sock", environment: variables).socket_path
    assert_equal "#{PRIVATE_DIRECTORY}/explicit", LibTmux::Endpoint.new(socket_name: "explicit", environment: variables).socket_path
    assert_equal "/explicit/tmux-#{Process.uid}/explicit",
      LibTmux::Endpoint.new(socket_name: "explicit", socket_directory: "/explicit", environment: variables).socket_path
  end

  def test_a_bad_variable_is_refused_by_name_without_echoing_its_value
    [["LIBTMUX_SOCKET", "private-a/b"], ["LIBTMUX_SOCKET", ".."], ["LIBTMUX_SOCKET_PATH", "private-\0path"]].each do |name, value|
      error = assert_raises(ArgumentError) { endpoint(name => value) }
      assert_includes error.message, name
      refute_includes error.message, "private-"
    end
  end

  def test_a_path_that_cannot_expand_is_refused_by_name_without_naming_the_user
    user = "libtmux-ruby-no-such-user"
    [[{socket_path: "~#{user}/x"}, "socket_path"],
      [{environment: {"LIBTMUX_SOCKET_PATH" => "~#{user}/x"}}, "LIBTMUX_SOCKET_PATH"],
      [{environment: {"TMUX" => "~#{user}/x,1,0"}}, "TMUX"],
      [{socket_name: "named", socket_directory: "~#{user}"}, "socket_directory"],
      [{environment: {"LIBTMUX_SOCKET" => "named", "TMUX_TMPDIR" => "~#{user}"}}, "TMUX_TMPDIR"]].each do |options, label|
      error = assert_raises(ArgumentError) { LibTmux::Endpoint.new(**options) }
      assert_includes error.message, label
      refute_includes error.message, user
    end
  end

  def test_from_env_follows_tmux_alone_and_ignores_the_variables
    variables = {"LIBTMUX_SOCKET_PATH" => "/variable/path.sock", "LIBTMUX_SOCKET" => "variable", "TMUX_TMPDIR" => TMUX_DIRECTORY}
    assert_equal "/inside/socket", LibTmux::Endpoint.from_env(variables.merge("TMUX" => "/inside/socket,1,0")).socket_path
    assert_equal "#{PRIVATE_DIRECTORY}/default", LibTmux::Endpoint.from_env(variables).socket_path
    assert_equal "#{PRIVATE_DIRECTORY}/default", LibTmux::Endpoint.from_env(variables.merge("TMUX" => ",1,0")).socket_path
  end

  def test_the_process_environment_is_the_default
    with_process_environment("LIBTMUX_SOCKET_PATH" => "/process/path.sock", "LIBTMUX_SOCKET" => nil, "TMUX" => nil) do
      assert_equal "/process/path.sock", LibTmux::Endpoint.new.socket_path
    end
    with_process_environment("LIBTMUX_SOCKET_PATH" => nil, "LIBTMUX_SOCKET" => "process", "TMUX" => nil,
      "TMUX_TMPDIR" => TMUX_DIRECTORY) do
      assert_equal "#{PRIVATE_DIRECTORY}/process", LibTmux::Endpoint.new.socket_path
    end
  end

  private

  # Every case names its own environment, so none reaches the tmux server of whoever runs the suite.
  def endpoint(variables = {})
    LibTmux::Endpoint.new(environment: variables)
  end

  def with_process_environment(variables)
    saved = variables.keys.to_h { |name| [name, ENV[name]] }
    variables.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end
end
