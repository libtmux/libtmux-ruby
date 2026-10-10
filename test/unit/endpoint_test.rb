# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../gems/libtmux/lib/libtmux/endpoint"

class EndpointTest < Minitest::Test
  def test_ordinary_constructor_uses_the_same_defaults_as_from_env
    env = {"LIBTMUX_SOCKET_PATH" => "/chosen/default.sock", "TMUX" => "ignored"}
    assert_equal "/chosen/default.sock", LibTmux::Endpoint.new(env: env).socket_path
    assert_equal "/tmp/tmux-#{Process.uid}/default", LibTmux::Endpoint.new(env: {}).socket_path
    assert_equal "/tmp/tmux-#{Process.uid}/default", LibTmux::Endpoint.new(env: {
      "LIBTMUX_SOCKET_PATH" => "", "LIBTMUX_SOCKET_NAME" => "", "TMUX" => "", "TMUX_TMPDIR" => ""
    }).socket_path
  end

  def test_complete_child_environment_and_executable_are_captured_without_host_mutation
    host = ENV.to_h
    Dir.mktmpdir("libtmux-ruby-endpoint-") do |directory|
      executable = File.join(directory, "tmux")
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o700, executable)
      env = {"PATH" => directory, "KEEP" => +"before", "DROP" => nil,
        "TMUX" => "/selected/socket,1,-1", "TMUX_PANE" => "%7"}
      endpoint = LibTmux::Endpoint.new(env: env)
      env.fetch("KEEP").replace("after")
      env["PATH"] = "/missing"
      assert_equal executable, endpoint.executable
      assert_equal({"PATH" => directory, "KEEP" => "before"}, endpoint.environment)
      assert endpoint.environment.frozen?
      assert endpoint.environment.values.all?(&:frozen?)
      assert_equal host, ENV.to_h
    end
  end

  def test_explicit_selector_ignores_invalid_lower_precedence_values
    env = {"LIBTMUX_SOCKET_PATH" => "relative", "LIBTMUX_SOCKET_NAME" => "../bad", "TMUX" => "bad", "TMUX_TMPDIR" => "relative"}
    assert_equal "/chosen/socket", LibTmux::Endpoint.new(socket_path: "/chosen/socket", env: env).socket_path
    assert_equal "/chosen/tmux-#{Process.uid}/name", LibTmux::Endpoint.new(socket_name: "name", socket_directory: "/chosen", env: env).socket_path
  end

  def test_selected_invalid_environment_never_uses_a_lower_endpoint
    [{"LIBTMUX_SOCKET_PATH" => "relative", "LIBTMUX_SOCKET_NAME" => "safe"},
      {"LIBTMUX_SOCKET_NAME" => "..", "TMUX" => "/safe/socket,1,0"},
      {"TMUX_TMPDIR" => "relative"}].each do |env|
      assert_raises(ArgumentError) { LibTmux::Endpoint.new(env: env) }
    end
  end

  def test_rejects_conflicting_or_invalid_explicit_selectors
    assert_raises(ArgumentError) do
      LibTmux::Endpoint.new(socket_path: "/unused", socket_name: "unused")
    end
    ["", ".", "..", "../escape", "a/b", "a\\b", "nul\0"].each do |name|
      assert_raises(ArgumentError) { LibTmux::Endpoint.new(socket_name: name) }
    end
    assert_raises(ArgumentError) { LibTmux::Endpoint.new(socket_path: "nul\0") }
    assert_raises(ArgumentError) { LibTmux::Endpoint.new(socket_path: "relative.sock") }
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

  def test_environment_path_wins_over_invalid_lower_selectors
    endpoint = LibTmux::Endpoint.from_env({
      "LIBTMUX_SOCKET_PATH" => "/owned/selected.sock",
      "LIBTMUX_SOCKET_NAME" => "../ignored",
      "TMUX" => "invalid",
      "TMUX_TMPDIR" => "relative"
    })
    assert_equal "/owned/selected.sock", endpoint.socket_path
  end

  def test_environment_name_wins_over_tmux_context
    endpoint = LibTmux::Endpoint.from_env({
      "LIBTMUX_SOCKET_PATH" => "",
      "LIBTMUX_SOCKET_NAME" => " selected ",
      "TMUX" => "invalid",
      "TMUX_TMPDIR" => "/owned/root"
    })
    assert_equal "/owned/root/tmux-#{Process.uid}/ selected ", endpoint.socket_path
  end

  def test_tmux_right_split_retains_commas_and_accepts_native_session_fields
    ["0", "004", "$4", "$004", "-1"].each do |session|
      endpoint = LibTmux::Endpoint.from_env({"TMUX" => "/owned/path,with,commas.sock,0012,#{session}"})
      assert_equal "/owned/path,with,commas.sock", endpoint.socket_path
    end
  end

  def test_invalid_tmux_context_does_not_fall_back
    [
      "/owned/socket,0,0", "/owned/socket,+1,0", "/owned/socket, 1,0",
      "/owned/socket,1,-2", "/owned/socket,1,+2", "/owned/socket,1,$",
      "/owned/socket,1,$$2", "/owned/socket,1,", "relative,1,0", "/owned/socket"
    ].each do |context|
      assert_raises(ArgumentError, context) { LibTmux::Endpoint.from_env({"TMUX" => context}) }
    end
  end

  def test_named_root_is_captured_and_invalid_child_environment_is_rejected
    env = {"TMUX_TMPDIR" => +"/selected/root", "LIBTMUX_SOCKET_NAME" => "chosen"}
    endpoint = LibTmux::Endpoint.new(env: env)
    env["TMUX_TMPDIR"].replace("/changed/root")
    assert_equal "/selected/root/tmux-#{Process.uid}/chosen", endpoint.socket_path
    [{"BAD=KEY" => "x"}, {"" => "x"}, {"KEY" => 1}, {"KEY" => "nul\0"}].each do |invalid|
      assert_raises(ArgumentError) { LibTmux::Endpoint.new(socket_path: "/unused", env: invalid) }
    end
  end

  def test_named_directory_rejects_a_different_uid_before_binding
    Dir.mktmpdir("libtmux-ruby-owner-") do |root|
      directory = File.join(root, "tmux-#{Process.uid}")
      Dir.mkdir(directory, 0o700)
      endpoint = LibTmux::Endpoint.new(socket_name: "selected", socket_directory: root)
      original = File.method(:lstat)
      foreign = original.call(directory)
      foreign.define_singleton_method(:uid) { Process.uid + 1 }
      File.define_singleton_method(:lstat) { |path| path == directory ? foreign : original.call(path) }
      begin
        assert_raises(ArgumentError) { endpoint.__send__(:validate_directory) }
      ensure
        File.define_singleton_method(:lstat, original)
      end
    end
  end

  def test_explicit_paths_retain_filesystem_parent_components
    raw = "/owned/missing/../selected.sock"
    assert_equal raw, LibTmux::Endpoint.new(socket_path: raw).socket_path
  end
end
