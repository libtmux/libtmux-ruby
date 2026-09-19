# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/workspace/cli"
require "stringio"
require "tmpdir"

class WorkspaceCLITest < Minitest::Test
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
      cases = [["validate", "--json", file], ["load", "--json", file],
        ["load", "--json", "--attach", "--switch", file],
        ["load", "--json", "--socket", "private-socket", "--switch", file],
        ["plan", "--json", "--live", file], ["load", "--json", "--timeout", "NaN", file],
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

  private

  def run_cli(arguments, directory)
    output, error = StringIO.new, StringIO.new
    status = LibTmux::Workspace::CLI.run(arguments, out: output, err: error, directory: directory, environment: {})
    [status, output.string, error.string]
  end
end
