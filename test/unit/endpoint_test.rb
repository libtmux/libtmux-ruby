# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../gems/libtmux/lib/libtmux/endpoint"

class EndpointTest < Minitest::Test
  def test_requires_an_explicit_endpoint_and_rejects_conflicting_selectors
    assert_raises(ArgumentError) { LibTmux::Endpoint.new }
    assert_raises(ArgumentError) do
      LibTmux::Endpoint.new(socket_path: "/unused", socket_name: "unused")
    end
    ["", "../escape", "a/b", "nul\0"].each do |name|
      assert_raises(ArgumentError) { LibTmux::Endpoint.new(socket_name: name) }
    end
    assert_raises(ArgumentError) { LibTmux::Endpoint.new(socket_path: "nul\0") }
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
end
