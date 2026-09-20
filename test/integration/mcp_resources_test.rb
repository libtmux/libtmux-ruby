# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux/mcp"

class McpResourcesTest < Minitest::Test
  def request(sdk, method, params = {})
    JSON.parse(JSON.generate(sdk.handle({jsonrpc: "2.0", id: 2, method: method, params: params})))
  end

  def initialized(app)
    app.sdk_server.tap do |sdk|
      request(sdk, "initialize", {protocolVersion: "2025-11-25", capabilities: {}, clientInfo: {name: "test", version: "1"}})
    end
  end

  def test_metadata_resources_reuse_tool_pages_and_reject_foreign_generation_and_policy
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        server.list_sessions.first.new_window(name: "second", command: ["cat"])
        Async do |task|
          LibTmux::Async.open(server: server, parent: task) do |scope|
            app = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test")
            sdk = initialized(app)
            templates = request(sdk, "resources/templates/list").dig("result", "resourceTemplates")
            refute_nil templates
            assert_equal 2, templates.length
            assert_equal ["application/json"], templates.map { |item| item.fetch("mimeType") }.uniq
            first = app.call("tmux_snapshot", {"entity" => "pane", "limit" => 1}).structured_content.fetch("data")
            generation = first.fetch("server_identity").fetch("generation")
            prefix = "tmux://test/#{generation}/snapshots/pane"
            cursor = first.fetch("next_cursor").sub(":", "%3A")
            result = request(sdk, "resources/read", {uri: "#{prefix}/pages/#{cursor}"})
            content = result.fetch("result").fetch("contents").fetch(0)
            assert_equal "application/json", content.fetch("mimeType")
            page = JSON.parse(content.fetch("text")).fetch("data")
            assert_equal first.fetch("capture_id"), page.fetch("capture_id")
            refute page.fetch("truncated")
            assert_equal 1, page.fetch("items").length
            live = request(sdk, "resources/read", {uri: prefix})
            assert_equal 2, JSON.parse(live.dig("result", "contents", 0, "text")).dig("data", "items").length

            other = prefix.sub(generation, "foreign-generation")
            assert_equal "stale_target", request(sdk, "resources/read", {uri: other}).dig("error", "data", "code")
            assert_equal "invalid_input", request(sdk, "resources/read", {uri: prefix + "/pages/%GG"}).dig("error", "data", "code")
            invalid = request(sdk, "resources/read", {uri: "tmux://PRIVATE_PAYLOAD/invalid"})
            refute_includes JSON.generate(invalid), "PRIVATE_PAYLOAD"

            denied = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test", enabled_tools: [])
            denied_sdk = initialized(denied)
            assert_equal "policy_denied", request(denied_sdk, "resources/read", {uri: prefix}).dig("error", "data", "code")

            pane_id = first.fetch("items").first.fetch("ref").fetch("id")
            screen_uri = "tmux://test/#{generation}/panes/#{pane_id.sub('%', '%25')}/screen"
            assert_equal "policy_denied", request(sdk, "resources/read", {uri: screen_uri}).dig("error", "data", "code")
            observer = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test", enabled_tools: ["tmux_capture"])
            observer_sdk = initialized(observer)
            screen = request(observer_sdk, "resources/read", {uri: screen_uri}).dig("result", "contents", 0)
            refute_nil screen
            assert_equal "text/plain", screen.fetch("mimeType")
            metadata = screen.fetch("_meta").fetch("io.github.libtmux/capture")
            assert_equal screen.fetch("text").bytesize, metadata.fetch("bytes")
            assert_equal "unknown", metadata.fetch("history_continuity")
            assert_nil metadata.fetch("process_generation")
            malformed = screen_uri.sub("%25", "%")
            assert_equal "invalid_input", request(observer_sdk, "resources/read", {uri: malformed}).dig("error", "data", "code")

            [app, denied, observer].each(&:close)
          end
        end.wait
      end
    end
  end
end
