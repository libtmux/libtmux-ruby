# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/mcp"

class MCPCatalogToolTest < Minitest::Test
  def test_tools_list_declares_object_schema_roots_for_the_negotiated_protocol
    names = %w[
      tmux_capabilities
      tmux_snapshot
      tmux_send
      tmux_create
      tmux_close
      tmux_run
      tmux_capture
      tmux_wait
    ]
    Async do
      application =
        LibTmux::MCP::Application.new(
          server: LibTmux::Async::Server.allocate,
          endpoint_name: "catalog",
          enabled_tools: names
        )
      sdk = application.sdk_server
      initialized =
        sdk.handle(
          {
            jsonrpc: "2.0",
            id: 1,
            method: "initialize",
            params: {
              protocolVersion: "2025-11-25",
              capabilities: {
              },
              clientInfo: {
                name: "test",
                version: "1"
              }
            }
          }
        )
      assert_equal "2025-11-25", initialized.fetch(:result).fetch(:protocolVersion)

      response =
        JSON.parse(JSON.generate(sdk.handle({ jsonrpc: "2.0", id: 2, method: "tools/list" })))
      tools = response.fetch("result").fetch("tools")
      assert_equal names, tools.map { |tool| tool.fetch("name") }
      tools.each do |tool|
        %w[inputSchema outputSchema].each do |key|
          assert_equal "object", tool.fetch(key)["type"], "#{tool.fetch("name")} #{key} root"
        end
      end
    ensure
      application&.close
    end.wait
  end

  def test_handshake_does_not_compile_tool_schemas_but_listing_validates_and_memoizes_them
    constructions = 0
    trace =
      TracePoint.new(:call) do |event|
        constructions += 1 if event.defined_class == ::MCP::Tool::Schema &&
          event.method_id == :initialize
      end
    Async do
      trace.enable(target: ::MCP::Tool::Schema.instance_method(:initialize)) do
        application =
          LibTmux::MCP::Application.new(
            server: LibTmux::Async::Server.allocate,
            endpoint_name: "catalog",
            enabled_tools: %w[tmux_capabilities tmux_snapshot tmux_send tmux_create tmux_close]
          )
        sdk = application.sdk_server
        response = sdk.handle({ jsonrpc: "2.0", id: 1, method: "server/discover" })
        assert response.fetch(:result).key?(:supportedVersions)
        assert_equal 0, constructions, "discovery compiled unused tool schemas"

        schemas = application.tools.map(&:to_h)
        assert_equal 10, constructions
        assert schemas.all? { |schema| schema.fetch(:inputSchema) && schema.fetch(:outputSchema) }
        assert_equal schemas, application.tools.map(&:to_h)
        assert_equal 10, constructions, "schema getters reconstructed validated schemas"
        tool = application.tools.find { |item| item.name_value == "tmux_send" }
        assert_raises(::MCP::Tool::InputSchema::ValidationError) do
          tool.input_schema_value.validate_arguments({})
        end
      ensure
        application&.close
      end
    end.wait
  ensure
    trace&.disable
  end

  def test_malformed_output_schema_is_rejected_before_exposure_or_operation_dispatch
    catalog = LibTmux::MCP.const_get(:Catalog)
    original = catalog.method(:output)
    catalog.define_singleton_method(:output) { |_name| { "type" => "invalid-schema-type" } }
    dispatches = 0
    server = LibTmux::Async::Server.allocate
    server.define_singleton_method(:snapshot) do |**_options|
      dispatches += 1
      raise "operation dispatched"
    end
    Async do
      application =
        LibTmux::MCP::Application.new(
          server: server,
          endpoint_name: "catalog",
          enabled_tools: ["tmux_capabilities"]
        )

      assert_raises(ArgumentError) { application.tools.first.to_h }
      response = application.call("tmux_capabilities").structured_content
      assert_equal "invalid_input", response.fetch("error").fetch("code")
      assert_equal 0, dispatches
    ensure
      application&.close
    end.wait
  ensure
    catalog&.define_singleton_method(:output, original) if original
  end
end
