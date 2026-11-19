# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/mcp"

class MCPCatalogToolTest < Minitest::Test
  CAPABILITY_KEY = "com.git-pull.libtmux-mcp/capability"
  TOOLSETS = %w[inspect manage execute teardown].freeze
  PROCESS_REACH = %w[none configured-process pane-input pane-command pane-program].freeze
  TMUX_EFFECTS = %w[observe change delete].freeze
  ALL_TOOLS = %w[tmux_capabilities tmux_snapshot tmux_send tmux_create tmux_close tmux_run tmux_capture tmux_wait].freeze
  CAPABILITIES = {
    "tmux_capabilities" => ["inspect", "none", %w[observe]],
    "tmux_snapshot" => ["inspect", "none", %w[observe]],
    "tmux_capture" => ["inspect", "none", %w[observe]],
    "tmux_wait" => ["inspect", "none", %w[observe]],
    "tmux_create" => ["execute", "pane-program", %w[observe change]],
    "tmux_send" => ["execute", "pane-input", %w[observe change]],
    "tmux_run" => ["execute", "pane-command", %w[observe change]],
    "tmux_close" => ["teardown", "none", %w[observe delete]]
  }.freeze

  def test_tools_list_declares_object_schema_roots_for_the_negotiated_protocol
    names = %w[tmux_capabilities tmux_snapshot tmux_send tmux_create tmux_close tmux_run tmux_capture tmux_wait]
    Async do
      application = LibTmux::MCP::Application.new(server: LibTmux::Async::Server.allocate,
        endpoint_name: "catalog", enabled_tools: names)
      sdk = application.sdk_server
      initialized = sdk.handle({jsonrpc: "2.0", id: 1, method: "initialize",
        params: {protocolVersion: "2025-11-25", capabilities: {}, clientInfo: {name: "test", version: "1"}}})
      assert_equal "2025-11-25", initialized.fetch(:result).fetch(:protocolVersion)

      response = JSON.parse(JSON.generate(sdk.handle({jsonrpc: "2.0", id: 2, method: "tools/list"})))
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
    trace = TracePoint.new(:call) do |event|
      constructions += 1 if event.defined_class == ::MCP::Tool::Schema && event.method_id == :initialize
    end
    Async do
      trace.enable(target: ::MCP::Tool::Schema.instance_method(:initialize)) do
        application = LibTmux::MCP::Application.new(server: LibTmux::Async::Server.allocate,
          endpoint_name: "catalog", enabled_tools: %w[tmux_capabilities tmux_snapshot tmux_send tmux_create tmux_close])
        sdk = application.sdk_server
        response = sdk.handle({jsonrpc: "2.0", id: 1, method: "server/discover"})
        assert response.fetch(:result).key?(:supportedVersions)
        assert_equal 0, constructions, "discovery compiled unused tool schemas"

        schemas = application.tools.map(&:to_h)
        assert_equal 10, constructions
        assert schemas.all? { |schema| schema.fetch(:inputSchema) && schema.fetch(:outputSchema) }
        assert_equal schemas, application.tools.map(&:to_h)
        assert_equal 10, constructions, "schema getters reconstructed validated schemas"
        tool = application.tools.find { |item| item.name_value == "tmux_send" }
        assert_raises(::MCP::Tool::InputSchema::ValidationError) { tool.input_schema_value.validate_arguments({}) }
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
    catalog.define_singleton_method(:output) { |_name| {"type" => "invalid-schema-type"} }
    dispatches = 0
    server = LibTmux::Async::Server.allocate
    server.define_singleton_method(:snapshot) { |**_options| dispatches += 1; raise "operation dispatched" }
    Async do
      application = LibTmux::MCP::Application.new(server: server, endpoint_name: "catalog",
        enabled_tools: ["tmux_capabilities"])

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

  def test_tools_list_states_the_capability_of_every_tool
    tools = listed_tools
    assert_equal ALL_TOOLS.sort, tools.map { |tool| tool.fetch("name") }.sort
    tools.each do |tool|
      toolset, process_reach, tmux_effects = CAPABILITIES.fetch(tool.fetch("name"))
      assert_equal({"toolset" => toolset, "processReach" => process_reach, "tmuxEffects" => tmux_effects},
        tool.dig("_meta", CAPABILITY_KEY), "#{tool.fetch("name")} capability")
    end
    assert_empty capability_problems(tools)
  end

  def test_capability_check_fails_a_missing_or_inconsistent_classification
    listed = listed_tools
    assert_empty capability_problems(listed), "the check must pass on the real listing before it can fail"
    mutations = {
      "tmux_send states no capability" => ["tmux_send", ->(tool) { tool.delete("_meta") }],
      %(tmux_send has unknown toolset "admin") => ["tmux_send", ->(tool) { tool["_meta"][CAPABILITY_KEY]["toolset"] = "admin" }],
      "tmux_snapshot is not observational inspect authority" => ["tmux_snapshot", ->(tool) { tool["_meta"][CAPABILITY_KEY]["processReach"] = "pane-input" }],
      "tmux_close is not direct teardown authority" => ["tmux_close", ->(tool) { tool["_meta"][CAPABILITY_KEY]["tmuxEffects"] = %w[observe] }],
      "tmux_run execute authority has no process reach" => ["tmux_run", ->(tool) { tool["_meta"][CAPABILITY_KEY]["processReach"] = "none" }]
    }
    mutations.each do |problem, (name, mutate)|
      tools = JSON.parse(JSON.generate(listed))
      mutate.call(tools.find { |tool| tool.fetch("name") == name })
      assert_includes capability_problems(tools), problem
    end
  end

  private

  def listed_tools(names = ALL_TOOLS)
    tools = nil
    Async do
      application = LibTmux::MCP::Application.new(server: LibTmux::Async::Server.allocate,
        endpoint_name: "catalog", enabled_tools: names)
      sdk = application.sdk_server
      sdk.handle({jsonrpc: "2.0", id: 1, method: "initialize",
        params: {protocolVersion: "2025-11-25", capabilities: {}, clientInfo: {name: "test", version: "1"}}})
      tools = JSON.parse(JSON.generate(sdk.handle({jsonrpc: "2.0", id: 2, method: "tools/list"}))).fetch("result").fetch("tools")
    ensure
      application&.close
    end.wait
    tools
  end

  # The rules mirror what the capability model requires of each toolset: an
  # inspect tool only observes and reaches no process, manage and teardown
  # reach none, teardown deletes, and execute reaches a process.
  def capability_problems(tools)
    tools.flat_map do |tool|
      name = tool.fetch("name")
      row = tool.dig("_meta", CAPABILITY_KEY)
      next ["#{name} states no capability"] unless row.is_a?(Hash)

      toolset, reach, effects = row.values_at("toolset", "processReach", "tmuxEffects")
      problems = []
      problems << "#{name} has unknown toolset #{toolset.inspect}" unless TOOLSETS.include?(toolset)
      problems << "#{name} has unknown processReach #{reach.inspect}" unless PROCESS_REACH.include?(reach)
      unless effects.is_a?(Array) && !effects.empty? && effects.uniq == effects && (effects - TMUX_EFFECTS).empty?
        problems << "#{name} has unknown tmuxEffects #{effects.inspect}"
      end
      problems << "#{name} is not observational inspect authority" if toolset == "inspect" && !(reach == "none" && effects == %w[observe])
      problems << "#{name} manage authority reaches a process" if toolset == "manage" && reach != "none"
      problems << "#{name} execute authority has no process reach" if toolset == "execute" && reach == "none"
      problems << "#{name} is not direct teardown authority" if toolset == "teardown" && !(reach == "none" && effects.include?("delete"))
      problems
    end
  end
end
