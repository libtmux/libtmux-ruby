# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/mcp/cli"
require "stringio"

class McpCLITest < Minitest::Test
  def test_broken_diagnostics_preserve_primary_failure_and_attempt_every_owner
    events = []
    primary = RuntimeError.new("private primary")
    error = StringIO.new
    error.close
    cli = LibTmux::MCP::CLI.__send__(:new, [], StringIO.new, StringIO.new, error)
    cli.define_singleton_method(:close_enrollments) { events << :enrollments }

    with_cli_owners(events, primary) do
      raised = assert_raises(RuntimeError) { cli.__send__(:serve, Object.new, Object.new) }
      assert_same primary, raised
    end
    assert_equal %i[transport enrollments application scope server], events
    assert_equal ["MCP cleanup failed (LibTmux::TransportError)", "MCP diagnostic failed (IOError)"], primary.mcp_cleanup_errors
    assert primary.mcp_cleanup_errors.frozen?
  end

  def test_broken_final_diagnostic_preserves_cli_status_after_cleanup
    error = StringIO.new
    error.close
    assert_equal 2, LibTmux::MCP::CLI.run([], err: error)

    input, output = IO.pipe
    [[RuntimeError.new("private execution"), 1], [LibTmux::Cancelled.new("private cancellation"), 130]].each do |primary, status|
      events = []
      with_cli_owners(events, primary) do
        assert_equal status, LibTmux::MCP::CLI.run(%w[--socket private-path], input: input, out: output, err: error)
      end
      assert_equal %i[transport application scope server], events
      details = primary.is_a?(LibTmux::Error) ? primary.cleanup_errors : primary.mcp_cleanup_errors
      assert_equal 2, details.count("MCP diagnostic failed (IOError)")
    end
  ensure
    [input, output].compact.each { |io| io.close unless io.closed? }
  end

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
      %w[--socket private-path --enroll-pane %0=private-setup],
      %w[--socket private-path --enable-tool tmux_run --enroll-pane name=private-setup],
      %w[--socket private-path --enable-tool tmux_run --enroll-pane %0=private-one --enroll-pane %0=private-two],
      %w[--socket private-path --enable-tool tmux_run --enroll-pane %0=private-one --enroll-pane %1=private-one],
      %w[--socket private-path --enrollment-timeout 301],
      %w[--socket private-path --unknown private-value]].each do |arguments|
      output, error = StringIO.new, StringIO.new
      assert_equal 2, LibTmux::MCP::CLI.run(arguments, out: output, err: error)
      assert_empty output.string
      assert_includes error.string, "Invalid arguments"
      refute_includes error.string, "private-"
    end
  end

  private

  def with_cli_owners(events, primary)
    server = Object.new
    scope = Struct.new(:server).new(server)
    app = Object.new
    app.define_singleton_method(:sdk_server) { Object.new }
    app.define_singleton_method(:close) { events << :application }
    transport = Object.new
    transport.define_singleton_method(:run) { raise primary }
    transport.define_singleton_method(:close) do
      events << :transport
      raise LibTmux::TransportError.new("private cleanup")
    end
    replacements = [
      [LibTmux::Endpoint, :new, ->(**_options) { Object.new }],
      [LibTmux::Server, :open, lambda do |**_options, &block|
        block.call(server)
      ensure
        events << :server
      end],
      [LibTmux::Async, :open, lambda do |**_options, &block|
        block.call(scope)
      ensure
        events << :scope
      end],
      [LibTmux::MCP::Application, :new, ->(**_options) { app }],
      [LibTmux::MCP::StdioTransport, :new, ->(**_options) { transport }]
    ]
    originals = replacements.map { |owner, method, _body| [owner, method, owner.method(method)] }
    replacements.each { |owner, method, body| owner.define_singleton_method(method, body) }
    yield
  ensure
    originals&.each { |owner, method, body| owner.define_singleton_method(method, body) }
  end
end
