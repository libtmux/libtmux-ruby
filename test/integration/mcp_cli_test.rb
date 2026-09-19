# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux/mcp/cli"
require "stringio"

class McpCLIIntegrationTest < Minitest::Test
  def test_cli_serves_real_protocol_and_eof_preserves_the_borrowed_daemon
    LibTmuxTest::TmuxFixture.open do |fixture|
      reader, input = IO.pipe
      output, writer = IO.pipe
      errors = StringIO.new
      application_closes = []
      trace = TracePoint.new(:call) do |event|
        if event.defined_class == LibTmux::MCP::Application && event.method_id == :close
          application_closes << Fiber.scheduler
        end
      end
      worker = Thread.new do
        LibTmux::MCP::CLI.run(["--socket", fixture.socket_path, "--endpoint", "test"],
          input: reader, out: writer, err: errors)
      end
      begin
        send_frame(input, id: 1, method: "initialize", params: {protocolVersion: "2025-11-25",
          capabilities: {}, clientInfo: {name: "test", version: "1"}})
        assert_equal "2025-11-25", frame(output).dig("result", "protocolVersion")
        send_frame(input, method: "notifications/initialized")
        send_frame(input, id: 2, method: "tools/list")
        assert_equal %w[tmux_capabilities tmux_snapshot], frame(output).fetch("result").fetch("tools").map { |tool| tool.fetch("name") }
        send_frame(input, id: 3, method: "tools/call", params: {name: "tmux_capabilities", arguments: {}})
        result = frame(output).dig("result", "structuredContent")
        assert result.fetch("ok")
        assert_equal "test", result.fetch("data").fetch("endpoint")
        trace.enable
        input.close
        assert worker.join(0.5), "MCP CLI did not retire after EOF"
        assert_equal 0, worker.value
        assert_equal 1, application_closes.length
        refute_nil application_closes.first
        assert_empty errors.string
        assert fixture.tmux("has-session").last.success?
      ensure
        trace.disable
        input.close unless input.closed?
        worker.join(0.5)
        worker.raise(Interrupt) if worker.alive?
        worker.join(0.5)
        [reader, output, writer].each { |io| io.close unless io.closed? }
      end
    end
  end

  private

  def send_frame(io, **message)
    io.write(JSON.generate({jsonrpc: "2.0", **message}) + "\n")
  end

  def frame(io)
    assert IO.select([io], nil, nil, 0.5), "MCP CLI did not return a frame"
    JSON.parse(io.gets)
  end
end
