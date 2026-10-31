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
    assert_equal 2, LibTmux::MCP::CLI.run(%w[--socket private-path --socket-name other], err: error)

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
    [%w[--socket private-path --socket-name other],
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

  def test_a_flag_names_the_socket_and_the_variables_name_it_otherwise
    directory = "/private-tmux-tmpdir"
    inside = "/inside/socket,1,0"
    cases = [
      [%w[--socket /flag/path.sock], {"LIBTMUX_SOCKET_PATH" => "/variable/path.sock", "LIBTMUX_SOCKET" => "variable"}, "/flag/path.sock"],
      [%w[--socket-name flag], {"LIBTMUX_SOCKET_PATH" => "/variable/path.sock"}, "#{directory}/tmux-#{Process.uid}/flag"],
      [[], {"LIBTMUX_SOCKET_PATH" => "/variable/path.sock"}, "/variable/path.sock"],
      [[], {"LIBTMUX_SOCKET" => "variable"}, "#{directory}/tmux-#{Process.uid}/variable"],
      [[], {"LIBTMUX_SOCKET_PATH" => "/variable/path.sock", "LIBTMUX_SOCKET" => "variable"}, "/variable/path.sock"],
      [[], {"TMUX" => inside}, "/inside/socket"],
      [[], {"LIBTMUX_SOCKET" => "variable", "TMUX" => inside}, "#{directory}/tmux-#{Process.uid}/variable"],
      [[], {}, "#{directory}/tmux-#{Process.uid}/default"]
    ]
    cases.each do |arguments, variables, socket|
      status, endpoint, error = serve_stopped(arguments, variables.merge("TMUX_TMPDIR" => directory))
      assert_equal 1, status, error
      assert_equal socket, endpoint.socket_path, "#{arguments} #{variables.keys}"
    end
  end

  def test_a_bad_variable_is_refused_by_name_before_any_server_opens
    status, endpoint, error = serve_stopped([], {"LIBTMUX_SOCKET" => "private-a/b", "TMUX_TMPDIR" => "/private-tmux-tmpdir"})
    assert_equal 2, status
    assert_nil endpoint
    assert_includes error, "LIBTMUX_SOCKET"
    refute_includes error, "private-"
  end

  def test_both_flags_are_refused_even_when_a_variable_names_a_socket
    status, endpoint, error = serve_stopped(%w[--socket /flag/path.sock --socket-name flag], {"LIBTMUX_SOCKET" => "variable"})
    assert_equal 2, status
    assert_nil endpoint
    # The CLI refuses the pair itself, in the words of its flags, before the core can.
    assert_equal "Invalid arguments; use --help for supported options.\n", error
  end

  private

  # Runs the CLI up to the point where it would open a server, and answers the
  # endpoint it chose. No tmux client starts.
  def serve_stopped(arguments, environment)
    chosen = []
    original = LibTmux::Server.method(:open)
    LibTmux::Server.define_singleton_method(:open) do |**options, &_block|
      chosen << options.fetch(:endpoint)
      raise LibTmux::TargetNotFoundError.new("stopped by the test", phase: :bind)
    end
    input, output = IO.pipe
    error = StringIO.new
    status = LibTmux::MCP::CLI.run(arguments, input: input, out: output, err: error, environment: environment)
    [status, chosen.first, error.string]
  ensure
    LibTmux::Server.define_singleton_method(:open, original)
    [input, output].compact.each { |io| io.close unless io.closed? }
  end

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
