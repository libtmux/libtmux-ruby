# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require_relative "../support/process_cursor_support"
require "libtmux/mcp"

class MCPCaptureTest < Minitest::Test
  include LibTmuxTest::ProcessCursorSupport
  def test_sdk_capture_retains_exact_bounded_states_and_rejects_foreign_or_respawned_cursors
    with_application do |app, sdk, scope, source|
      supported = require_process_cursor_support(app, scope)
      assert_includes [true, false], supported, "process support must select a proved positive or refusal branch"
      next unless supported
      pane = scope.server.list_panes.first
      target = wire_ref(pane.ref)
      first = invoke(sdk, target: target, track: true, max_lines: 24)
      assert first.fetch("ok"), first.inspect
      first = first.fetch("data")
      assert_equal "snapshot", first.fetch("mode")
      assert_equal "unknown", first.fetch("history_continuity")
      assert_equal "utf-8", first.fetch("encoding")
      with_output(scope, pane) { pane.send_text("delta-visible") }
      next_page = invoke(sdk, target: target, cursor: first.fetch("next_cursor"))
      assert next_page.fetch("ok"), next_page.inspect
      delta = next_page.fetch("data")
      assert_equal first.fetch("capture_id"), delta.fetch("base_capture_id")
      rows = first.fetch("rows").dup
      splice = delta.fetch("splice")
      rows[splice.fetch("start"), splice.fetch("delete")] = splice.fetch("rows")
      actual = invoke(sdk, target: target, max_lines: 24).fetch("data")
      assert_equal actual.fetch("rows"), rows
      assert rows.join.include?("delta-visible")
      assert_equal first.fetch("process_generation"), delta.fetch("process_generation")

      other = target.merge("generation" => "another-binding")
      assert_equal "stale_cursor", invoke(sdk, target: other, cursor: delta.fetch("next_cursor")).dig("error", "code")
      assert_equal "invalid_input", invoke(sdk, target: target, cursor: delta.fetch("next_cursor"), max_bytes: 10).dig("error", "code")
      pane.respawn(command: ["cat"], kill: true)
      assert_equal "stale_cursor", invoke(sdk, target: target, cursor: delta.fetch("next_cursor")).dig("error", "code")
      app.close
      app.close
      assert_equal "closed", invoke(sdk, target: target).dig("error", "code")
      assert source.run(["has-session", "-t", "fixture"]).success?
    end
  end

  def test_screen_capture_refuses_after_hooks_and_preserves_split_utf8_bytes
    with_application do |app, sdk, scope, source|
      session = scope.server.new_session(name: "one-row", command: ["cat"], width: 20, height: 1)
      window = session.list_windows.first
      window.resize(width: 20, height: 1)
      pane = window.list_panes.first
      target = wire_ref(pane.ref)
      with_output(scope, pane, session: session, expected: "éé") { pane.send_text("éé") }
      full = invoke(sdk, target: target, max_lines: 1).fetch("data")
      limited = invoke(sdk, target: target, max_lines: 1, max_bytes: 4).fetch("data")
      assert_equal "base64", limited.fetch("encoding")
      assert_equal full.fetch("rows").join.b.byteslice(-4, 4), limited.fetch("rows").map { |row| row.unpack1("m0") }.join.b
      assert limited.fetch("truncated")
      ["display-message -p not-screen", "wait-for capture-must-not-wait"].each do |command|
        session.hooks.set("after-capture-pane", command: command, index: 17)
        refused = invoke(sdk, target: target)
        assert_equal "unsupported", refused.dig("error", "code"), refused.inspect
        session.hooks.unset("after-capture-pane", index: 17)
      end
      session.hooks.unset("after-capture-pane")
      scope.server.hooks.set("after-capture-pane", command: "display-message -p inherited-not-screen", index: 503)
      refused = invoke(sdk, target: target)
      assert_equal "unsupported", refused.dig("error", "code"), refused.inspect

      session.hooks.set("after-capture-pane", command: "")
      restored = invoke(sdk, target: target, max_lines: 1)
      assert restored.fetch("ok"), restored.inspect
      assert_equal full.fetch("rows"), restored.fetch("data").fetch("rows")
    end
  end

  private

  def with_application(**options)
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path, executable: fixture.executable) do |source|
        Async do |task|
          LibTmux::Async.open(server: source, parent: task) do |scope|
            app = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test",
              enabled_tools: %w[tmux_capabilities tmux_snapshot tmux_capture tmux_wait], **options)
            begin
              yield app, app.sdk_server, scope, source
            ensure
              app.close if app.respond_to?(:close)
            end
          end
        end.wait
      end
    end
  end

  def invoke(sdk, **arguments)
    response = sdk.handle({jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: "tmux_capture", arguments: arguments}})
    JSON.parse(JSON.generate(response)).fetch("result").fetch("structuredContent")
  end

  def wire_ref(ref)
    {"generation" => ref.binding_key, "kind" => ref.kind.to_s, "id" => ref.id}
  end

  def with_output(scope, pane, session: scope.server.list_sessions.first, expected: nil)
    scope.server.open_control(session: session.ref) do |control|
      events = control.subscribe(pane_id: pane.id)
      control.exchange("display-message -p ready", timeout: 0.5)
      yield
      received = +"".b
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
      loop do
        event = events.next(timeout: deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
        next unless event.kind == :output

        received << event.data
        break unless expected && !received.include?(expected.b)
      end
    ensure
      events&.close
    end
  end
end
