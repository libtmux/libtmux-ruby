# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/workspace/cli"
require "stringio"
require "tmpdir"

class WorkspaceCLITest < Minitest::Test
  def test_version_does_not_require_configuration_or_a_tmux_endpoint
    [[], %w[validate], %w[plan], %w[load]].each do |command|
      status, output, error = run_cli([*command, "--version"], "/libtmux-ruby-missing-config")
      assert_equal 0, status
      assert_equal "#{LibTmux::Workspace::VERSION}\n", output
      assert_empty error
    end
  end

  def test_validation_discovery_and_offline_plan_are_inert_and_render_the_same_plan
    Dir.mktmpdir("libtmux-ruby-cli-") do |directory|
      file = File.join(directory, ".tmuxp.json")
      File.write(file, JSON.generate({session_name: "cli", windows: [{window_name: "one", panes: [{shell_command: "touch must-not-run"}]}]}))
      status, output, error = run_cli(%w[validate --json], directory)
      assert_equal 0, status
      assert_equal true, JSON.parse(output).fetch("valid")
      assert_empty error
      status, output, error = run_cli(%w[plan --json], directory)
      assert_equal 0, status
      assert_equal LibTmux::Workspace.load(file).plan.to_h, JSON.parse(output)
      assert_empty error
      refute File.exist?(File.join(directory, "must-not-run"))
      assert_equal 0, run_cli(["plan", file], directory).first
      File.write(File.join(directory, ".tmuxp.yaml"), "session_name: other")
      status, output, error = run_cli(%w[validate --json], directory)
      assert_equal 2, status
      assert_equal "arguments", JSON.parse(output).fetch("error").fetch("kind")
      assert_empty error
    end
  end

  def test_invalid_arguments_and_configuration_return_two_without_echoing_payloads
    Dir.mktmpdir("libtmux-ruby-cli-") do |directory|
      file = File.join(directory, "private-config.json")
      File.write(file, '{"session_name":"a","session_name":"secret-name"}')
      cases = [["validate", "--json", file], ["load", "--json", "--socket", "private-socket", file],
        ["load", "--json", "--attach", "--switch", file],
        ["load", "--json", "--socket", "private-socket", "--switch", file],
        ["plan", "--json", "--live", "--socket", "private-socket", file], ["load", "--json", "--timeout", "NaN", file],
        ["validate", "--json", "--unknown=private-value", file]]
      cases.each do |arguments|
        status, output, error = run_cli(arguments, directory)
        assert_equal 2, status
        assert JSON.parse(output).key?("error")
        refute_includes output, "private-"
        refute_includes output, "secret-name"
        assert_empty error
      end
      status, output, error = run_cli(%w[--help], directory)
      assert_equal 0, status
      assert_includes output, "validate|plan|load"
      assert_empty error
    end
  end

  def test_only_floor_refusals_get_the_unsupported_code
    floor = LibTmux::Internal::TmuxVersion
    below = assert_raises(LibTmux::UnsupportedFeatureError) { floor.require_supported("3.2a") }
    changed = LibTmux::UnsupportedFeatureError.new("the tmux daemon no longer reports 3.3a; reopen the server",
      phase: :admission, delivery: :not_sent, expected: floor::EXPECTED)
    unrelated = LibTmux::UnsupportedFeatureError.new("native waitid is unavailable", phase: :admission, delivery: :not_sent)
    Dir.mktmpdir("libtmux-ruby-cli-") do |directory|
      file = File.join(directory, "load.json")
      File.write(file, JSON.generate({session_name: "refused", windows: [{window_name: "one", panes: [{}]}]}))
      socket = File.join(directory, "socket")
      [[below, true], [changed, true], [floor.unrecognized("master", "the daemon"), true], [unrelated, false]].each do |error, refusal|
        status, output, = with_open_raising(error) { run_cli(["load", file, "--json", "--socket", socket], directory) }
        failure = JSON.parse(output).fetch("error")
        assert_equal 1, status
        assert_equal refusal ? "tmux_unsupported" : "execution", failure.fetch("kind"), error.message
        assert_equal error.message, failure.fetch("message")
        _, plain, shown = with_open_raising(error) { run_cli(["load", file, "--socket", socket], directory) }
        assert_empty plain
        assert_equal "#{error.message}\n", shown
      end
    end
  end

  def test_load_and_live_plan_take_the_socket_the_core_picks_when_no_flag_names_one
    directory = "/private-tmux-tmpdir"
    inside = "/inside/socket,1,0"
    named = "#{directory}/tmux-#{Process.uid}"
    cases = [
      [{"LIBTMUX_SOCKET_PATH" => "/variable/path.sock", "LIBTMUX_SOCKET" => "variable"}, "/variable/path.sock"],
      [{"LIBTMUX_SOCKET" => "variable"}, "#{named}/variable"],
      [{"TMUX" => inside}, "/inside/socket"],
      [{"LIBTMUX_SOCKET" => "variable", "TMUX" => inside}, "#{named}/variable"],
      [{}, "#{named}/default"]
    ]
    Dir.mktmpdir("libtmux-ruby-cli-") do |work|
      file = write_config(work)
      [["load"], ["plan", "--live"]].each do |command|
        cases.each do |variables, socket|
          status, endpoints, = capturing_open { |environment| run_cli([*command, "--json", file], work, environment: environment.merge(variables)) }
          assert_equal 1, status, "#{command} #{variables.keys}"
          assert_equal [socket], endpoints.map(&:socket_path), "#{command} #{variables.keys}"
        end
      end
    end
  end

  def test_the_socket_flag_wins_over_every_variable
    Dir.mktmpdir("libtmux-ruby-cli-") do |work|
      file = write_config(work)
      variables = {"LIBTMUX_SOCKET_PATH" => "/variable/path.sock", "LIBTMUX_SOCKET" => "variable", "TMUX" => "/inside/socket,1,0"}
      [["load"], ["plan", "--live"]].each do |command|
        _, endpoints, = capturing_open do |environment|
          run_cli([*command, "--json", "--socket", "flag.sock", file], work, environment: environment.merge(variables))
        end
        assert_equal [File.join(work, "flag.sock")], endpoints.map(&:socket_path), command.inspect
      end
    end
  end

  def test_a_bad_variable_is_refused_by_name_before_any_server_opens
    Dir.mktmpdir("libtmux-ruby-cli-") do |work|
      file = write_config(work)
      status, endpoints, output = capturing_open do |environment|
        run_cli(["load", "--json", file], work, environment: environment.merge("LIBTMUX_SOCKET" => "private-a/b"))
      end
      assert_equal 2, status
      assert_empty endpoints
      assert_includes output, "LIBTMUX_SOCKET"
      refute_includes output, "private-"
    end
  end

  def test_an_empty_socket_flag_and_a_socket_flag_without_a_live_command_are_refused_before_any_server_opens
    Dir.mktmpdir("libtmux-ruby-cli-") do |work|
      file = write_config(work)
      [["load", "--socket", ""], ["plan", "--live", "--socket", ""], ["plan", "--socket", "flag.sock"],
        ["validate", "--socket", "flag.sock"]].each do |arguments|
        status, endpoints, = capturing_open { |environment| run_cli([*arguments, "--json", file], work, environment: environment) }
        assert_equal 2, status, arguments.inspect
        assert_empty endpoints, arguments.inspect
      end
    end
  end

  private

  def write_config(directory)
    file = File.join(directory, "workspace.json")
    File.write(file, JSON.generate({session_name: "cli", windows: [{window_name: "one", panes: [{}]}]}))
    file
  end

  # Stops the CLI where it would open a server, so no tmux client starts, and
  # answers the status, the endpoints it was asked to open and its output. The
  # block gets an environment whose tmux directory is private.
  def capturing_open
    endpoints = []
    original = LibTmux::Server.method(:open)
    LibTmux::Server.define_singleton_method(:open) do |**options, &_block|
      endpoints << options.fetch(:endpoint)
      raise LibTmux::TargetNotFoundError.new("stopped by the test", phase: :bind)
    end
    status, output, = yield({"TMUX_TMPDIR" => "/private-tmux-tmpdir"})
    [status, endpoints, output]
  ensure
    LibTmux::Server.define_singleton_method(:open, original)
  end

  def with_open_raising(error)
    original = LibTmux::Server.method(:open)
    LibTmux::Server.define_singleton_method(:open) { |**| raise error }
    yield
  ensure
    LibTmux::Server.define_singleton_method(:open, original)
  end

  def run_cli(arguments, directory, environment: {})
    output, error = StringIO.new, StringIO.new
    status = LibTmux::Workspace::CLI.run(arguments, out: output, err: error, directory: directory, environment: environment)
    [status, output.string, error.string]
  end
end
