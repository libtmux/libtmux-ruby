# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/mcp/cli"
require "stringio"

class McpCLITest < Minitest::Test
  def test_help_version_and_invalid_arguments_do_not_open_an_endpoint
    [%w[--help], %w[--version]].each do |arguments|
      output, error = StringIO.new, StringIO.new
      assert_equal 0, LibTmux::MCP::CLI.run(arguments, out: output, err: error)
      refute_empty output.string
      assert_empty error.string
    end
    [[], %w[--socket private-path --socket-name other],
      %w[--socket private-path --timeout NaN], %w[--socket private-path --concurrency 0],
      %w[--socket private-path --enable-tool unrecognized],
      %w[--socket private-path --unknown private-value]].each do |arguments|
      output, error = StringIO.new, StringIO.new
      assert_equal 2, LibTmux::MCP::CLI.run(arguments, out: output, err: error)
      assert_empty output.string
      assert_includes error.string, "Invalid arguments"
      refute_includes error.string, "private-"
    end
  end
end
