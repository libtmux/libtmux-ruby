# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux/mcp"
require "libtmux/mcp/application" if File.exist?(File.expand_path("../../gems/libtmux-mcp/lib/libtmux/mcp/application.rb", __dir__))

class McpApplicationTest < Minitest::Test
  def test_discovery_and_snapshot_pages_share_the_captured_query_and_enforce_policy
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.list_sessions.first
        session.new_window(name: "second", command: ["cat"])
        Async do |task|
          LibTmux::Async.open(server: server, parent: task) do |scope|
            app = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test")
            capabilities = app.call("tmux_capabilities").structured_content
            assert capabilities.fetch("ok")
            assert_equal "test", capabilities.fetch("data").fetch("endpoint")
            assert_equal %w[tmux_capabilities tmux_snapshot], capabilities.fetch("data").fetch("enabled_tools")
            assert_equal LibTmux::FilterExpr.json_schema, capabilities.fetch("data").fetch("criteria_schema")
            assert app.tools.first.call.structured_content.fetch("ok")
            first = app.call("tmux_snapshot", {"entity" => "pane", "limit" => 1}).structured_content
            assert first.fetch("ok")
            data = first.fetch("data")
            assert data.fetch("truncated")
            assert_equal 1, data.fetch("items").length
            session.new_window(name: "after-capture", command: ["cat"])
            second = app.call("tmux_snapshot", {"cursor" => data.fetch("next_cursor")}).structured_content.fetch("data")
            assert_equal data.fetch("capture_id"), second.fetch("capture_id")
            refute second.fetch("truncated")
            assert_equal 1, second.fetch("items").length
            assert_equal 2, [*data.fetch("items"), *second.fetch("items")].map { |item| item.fetch("ref").fetch("id") }.uniq.length
            denied = app.call("tmux_close", {"anything" => "private"})
            assert denied.error?
            assert_equal "policy_denied", denied.structured_content.fetch("error").fetch("code")
            refute_includes JSON.generate(denied.to_h), "private"
            app.tools.each do |tool|
              response = tool.name_value == "tmux_capabilities" ? capabilities : first
              tool.output_schema_value.validate_result(response)
            end
          end
        end.wait
      end
    end
  end

  def test_invalid_criteria_foreign_and_expired_cursors_never_refresh_implicitly
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        server.list_sessions.first.new_window(name: "second", command: ["cat"])
        Async do |task|
          LibTmux::Async.open(server: server, parent: task) do |scope|
            app = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test", max_captures: 1)
            first = app.call("tmux_snapshot", {"entity" => "pane", "limit" => 1}).structured_content.fetch("data")
            app.call("tmux_snapshot", {"entity" => "session"})
            expired = app.call("tmux_snapshot", {"cursor" => first.fetch("next_cursor")})
            assert expired.error?
            assert_equal "stale_cursor", expired.structured_content.fetch("error").fetch("code")
            foreign = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "other")
            assert foreign.call("tmux_snapshot", {"cursor" => first.fetch("next_cursor")}).error?
            original = scope.server.method(:snapshot)
            scope.server.define_singleton_method(:snapshot) { |**options| flunk "invalid filter performed tmux I/O" }
            begin
              invalid = app.call("tmux_snapshot", {"entity" => "pane", "criteria" =>
                {"profile" => "foreign", "version" => 1, "entity" => "pane", "where" => {}}})
              assert invalid.error?
              sdk = app.sdk_server
              sdk.handle({jsonrpc: "2.0", id: 1, method: "initialize", params: {
                protocolVersion: "2025-11-25", capabilities: {}, clientInfo: {name: "test", version: "1"}}})
              response = sdk.handle({jsonrpc: "2.0", id: 2, method: "tools/call", params: {
                name: "tmux_snapshot", arguments: {entity: "pane", PRIVATE_KEY_SENTINEL: "secret-value"}}})
              normalized = JSON.parse(JSON.generate(response))
              refute_includes JSON.generate(normalized), "PRIVATE_KEY_SENTINEL"
              assert_equal "invalid_input", normalized.dig("result", "structuredContent", "error", "code")
            ensure
              scope.server.define_singleton_method(:snapshot, original)
            end
          end
        end.wait
      end
    end
  end

  def test_an_oversized_first_page_does_not_evict_a_usable_capture
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        server.list_sessions.first.new_window(name: "second", command: ["cat"])
        Async do |task|
          LibTmux::Async.open(server: server, parent: task) do |scope|
            app = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test",
              max_captures: 1, max_response_bytes: 2048)
            first = app.call("tmux_snapshot", {"entity" => "pane", "limit" => 1}).structured_content.fetch("data")
            assert scope.server.run(["select-pane", "-t", first.fetch("items").first.fetch("ref").fetch("id"), "-T", "x" * 6000]).success?
            oversized = app.call("tmux_snapshot", {"entity" => "pane"})
            assert oversized.error?
            assert_equal "capacity", oversized.structured_content.fetch("error").fetch("code")
            next_page = app.call("tmux_snapshot", {"cursor" => first.fetch("next_cursor")})
            refute next_page.error?
            assert_equal first.fetch("capture_id"), next_page.structured_content.fetch("data").fetch("capture_id")
          end
        end.wait
      end
    end
  end
end
