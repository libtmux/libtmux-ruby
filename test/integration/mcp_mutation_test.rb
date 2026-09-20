# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux/mcp"

class MCPMutationTest < Minitest::Test
  MUTATORS = %w[tmux_send tmux_create tmux_close].freeze

  def test_opt_in_sdk_mutations_create_exact_entities_and_separate_text_from_keys
    with_application do |app, sdk, scope, source, fixture|
      created = invoke(sdk, "tmux_create", kind: "session", name: 'literal-#{session_id};',
        window_name: 'initial-#{pane_id};', argv: ["cat"])
      assert created.fetch("ok"), created.inspect
      session = created.fetch("data").fetch("entity")
      assert_equal "session", session.fetch("kind")
      assert_equal %w[session window pane], created.fetch("data").fetch("created").map { |ref| ref.fetch("kind") }
      assert_equal "unobserved", created.fetch("data").fetch("program_completion")

      result_file = File.join(File.dirname(fixture.socket_path), "received.json")
      receiver = 'File.binwrite(ARGV[0], Marshal.dump([STDIN.gets, Dir.pwd, ENV["MCP_LITERAL"], ARGV[2]])); system("tmux", "-S", ARGV[1], "wait-for", "-S", "mcp-received"); STDIN.read'
      window = invoke(sdk, "tmux_create", kind: "window", parent: session, name: 'window-#{window_id};',
        index: 3, cwd: File.dirname(fixture.socket_path), environment: {MCP_LITERAL: "env;literal"},
        argv: [Gem.ruby, "--disable=rubyopt,gems", "-e", receiver, result_file, fixture.socket_path, "argv;literal"])
      assert window.fetch("ok"), window.inspect
      window_data = window.fetch("data")
      pane = window_data.fetch("created").find { |ref| ref.fetch("kind") == "pane" }
      text = 'literal; #{pane_id} Enter'
      sent = invoke(sdk, "tmux_send", target: pane, input: {type: "text", text: text})
      assert sent.fetch("ok"), sent.inspect
      assert_equal "dispatch_only", sent.fetch("data").fetch("completion")
      refute File.exist?(result_file)
      assert invoke(sdk, "tmux_send", target: pane, input: {type: "keys", keys: ["Enter"]}).fetch("ok")
      scope.server.wait_for("mcp-received", timeout: 0.5)
      assert_equal [text + "\n", File.realpath(File.dirname(fixture.socket_path)), "env;literal", "argv;literal"], Marshal.load(File.binread(result_file))

      split = invoke(sdk, "tmux_create", kind: "pane", parent: pane, direction: "vertical", size: "25%", argv: ["cat"])
      assert split.fetch("ok"), split.inspect
      split_ref = split.fetch("data").fetch("entity")
      assert_equal [split_ref], split.fetch("data").fetch("created")
      snapshot = scope.server.snapshot
      assert_equal 'literal-#{session_id};', snapshot.sessions.find { |record| record.id == session.fetch("id") }.name
      link = snapshot.window_links.find { |record| record.window_id == window_data.fetch("entity").fetch("id") }
      assert_equal 3, link.index
      assert_equal pane.fetch("id"), snapshot.panes.find { |record| record.id == pane.fetch("id") }.id
      [split_ref, window_data.fetch("entity"), session].each do |ref|
        closed = invoke(sdk, "tmux_close", target: ref)
        assert closed.fetch("ok"), closed.inspect
        assert_equal 0, closed.fetch("data").fetch("client_exit_status")
      end
      assert source.run(["has-session", "-t", "fixture"]).success?
    end
  end

  def test_default_policy_and_invalid_or_foreign_targets_refuse_before_mutation
    with_application do |app, sdk, scope, source, fixture|
      restricted = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test")
      list = restricted.sdk_server.handle({jsonrpc: "2.0", id: 1, method: "tools/list"})
      assert_equal %w[tmux_capabilities tmux_snapshot], list.fetch(:result).fetch(:tools).map { |tool| tool.fetch(:name) }
      MUTATORS.each do |name|
        assert_equal "policy_denied", restricted.call(name, {"PRIVATE_SENTINEL" => "secret"}).structured_content.dig("error", "code")
      end
      snapshot = scope.server.snapshot
      local = snapshot.panes.first.ref
      pane = wire_ref(local)
      LibTmux::Server.open(socket_path: fixture.socket_path) do |other|
        foreign = wire_ref(other.list_panes.first.ref)
        assert_equal pane.fetch("id"), foreign.fetch("id")
        denied = invoke(sdk, "tmux_close", target: foreign)
        assert_equal "stale_target", denied.dig("error", "code")
        assert_equal "not_sent", denied.dig("error", "delivery")
      end
      malformed = invoke(sdk, "tmux_send", target: pane, input: {type: "text", text: "private", keys: ["Enter"]})
      assert_equal "invalid_input", malformed.dig("error", "code")
      refute_includes JSON.generate(malformed), "private"
      assert_equal "invalid_input", invoke(sdk, "tmux_send", target: pane).dig("error", "code")
      missing = pane.merge("id" => "%999999999")
      assert_equal "stale_target", invoke(sdk, "tmux_send", target: missing, input: {type: "text", text: "wrong target"}).dig("error", "code")
      acquired = 0
      original = scope.server.method(:snapshot)
      scope.server.define_singleton_method(:snapshot) { |**options| acquired += 1; original.call(**options) }
      begin
        parent = wire_ref(snapshot.sessions.first.ref)
        [["valid", [""]], ["", ["cat"]]].each do |name, argv|
          invalid = invoke(sdk, "tmux_create", kind: "window", parent: parent, name: name, argv: argv)
          assert_equal "invalid_input", invalid.dig("error", "code")
        end
        oversized = invoke(sdk, "tmux_send", target: pane, input: {type: "text", text: "é" * 32_769})
        assert_equal "capacity", oversized.dig("error", "code")
        assert_equal "none", oversized.dig("error", "effects", "state")
        cancelled = ::MCP::Cancellation.new(request_id: 30)
        cancelled.cancel
        response = app.call("tmux_close", {"target" => pane}, cancellation: cancelled).structured_content
        assert_equal "cancelled", response.dig("error", "code")
        assert_equal "not_sent", response.dig("error", "delivery")
        assert_equal 0, acquired
      ensure
        scope.server.define_singleton_method(:snapshot, original)
      end
      assert source.run(["has-session", "-t", "fixture"]).success?
    end
  end

  def test_mutation_response_capacity_is_reserved_before_any_creation
    with_application do |app, sdk, scope, source, fixture|
      assert_raises(ArgumentError) do
        LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "small", enabled_tools: ["tmux_create"], max_response_bytes: 4095)
      end
      tool = app.tools.find { |entry| entry.name_value == "tmux_create" }
      refs = [["session", "$"], ["window", "@"], ["pane", "%"]].map do |kind, prefix|
        {"generation" => "\u0001" * 128, "kind" => kind, "id" => prefix + "9" * 31}
      end
      success = {"ok" => true, "data" => {"entity" => refs.first, "created" => refs,
        "delivery" => "observed", "program_completion" => "unobserved"}}
      failure = {"ok" => false, "error" => {"code" => "capacity", "message" => "The operation could not establish its requested result.",
        "delivery" => "observed", "effects" => {"state" => "known", "created" => refs}}}
      [success, failure].each do |structured|
        tool.output_schema_value.validate_result(structured)
        response = ::MCP::Tool::Response.new([{type: "text", text: "tmux_create completed; structuredContent contains the result."}], structured_content: structured)
        assert_operator JSON.generate(response.to_h).bytesize, :<=, 4096
      end
      app.define_singleton_method(:validate_response_size) do |structured|
        raise LibTmux::CapacityError.new("injected final response admission failure", delivery: :observed)
      end
      result = invoke(sdk, "tmux_create", kind: "session", name: "known-effect", argv: ["cat"])
      assert_equal "capacity", result.dig("error", "code")
      assert_equal "known", result.dig("error", "effects", "state")
      actual = scope.server.list_sessions.find { |entry| entry.snapshot.name == "known-effect" }
      assert_equal actual.id, result.dig("error", "effects", "created", 0, "id")
      assert_operator JSON.generate(result).bytesize, :<=, 4096
    end
  end

  def test_one_deadline_covers_acquisition_and_mutation_and_preserves_unknown_effects
    with_application(request_timeout: 0.1) do |app, sdk, scope, source, fixture|
      parent = ::Async::Task.current
      session = wire_ref(scope.server.snapshot.sessions.first.ref)
      seen = []
      scope.server.define_singleton_method(:snapshot) do |**options|
        seen << [:capture, options.fetch(:timeout), options.fetch(:cancel)]
        super(**options)
      end
      scope.server.define_singleton_method(:create_window) do |ref, **options|
        seen << [:mutation, options.fetch(:timeout), options.fetch(:cancel)]
        super(ref, **options)
      end
      source.hooks.set("after-new-window", command: "wait-for -S mcp-created ; wait-for mcp-create-held", index: 93)
      begin
        pending = parent.async { invoke(sdk, "tmux_create", kind: "window", parent: session, name: "partial-effect", argv: ["cat"]) }
        scope.server.wait_for("mcp-created", timeout: 0.5)
        failure = pending.wait(timeout: 0.5)
        assert_equal "deadline", failure.dig("error", "code")
        assert_equal "possibly_sent", failure.dig("error", "delivery")
        assert_equal({"state" => "unknown", "created" => []}, failure.dig("error", "effects"))
        assert_operator seen.fetch(1).fetch(1), :<, seen.fetch(0).fetch(1)
        assert_same seen.fetch(0).fetch(2), seen.fetch(1).fetch(2)
        assert scope.server.run(["list-windows", "-a", "-F", '#{window_name}']).text.lines.any? { |line| line.chomp == "partial-effect" }
      ensure
        scope.server.wait_for("mcp-create-held", action: :signal, timeout: 0.5)
        source.hooks.unset("after-new-window", index: 93)
      end

      source.options.set("command-alias", "display-message=wait-for -S mcp-acquire-ready ; wait-for mcp-acquire-held ; display-message", index: 93)
      begin
        pending = parent.async { invoke(sdk, "tmux_create", kind: "window", parent: session, name: "never-dispatched", argv: ["cat"]) }
        scope.server.wait_for("mcp-acquire-ready", timeout: 0.5)
        failure = pending.wait(timeout: 0.5)
        assert_equal "deadline", failure.dig("error", "code")
        assert_equal "not_sent", failure.dig("error", "delivery")
        assert_equal({"state" => "none", "created" => []}, failure.dig("error", "effects"))
      ensure
        scope.server.wait_for("mcp-acquire-held", action: :signal, timeout: 0.5)
        source.options.unset("command-alias", index: 93)
      end
      refute scope.server.run(["list-windows", "-a", "-F", '#{window_name}']).text.lines.any? { |line| line.chomp == "never-dispatched" }
    end
  end

  private

  def with_application(**options)
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |source|
        Async do |task|
          LibTmux::Async.open(server: source, parent: task) do |scope|
            app = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test",
              enabled_tools: %w[tmux_capabilities tmux_snapshot] + MUTATORS, **options)
            sdk = app.sdk_server
            sdk.handle({jsonrpc: "2.0", id: 1, method: "initialize", params: {
              protocolVersion: "2025-11-25", capabilities: {}, clientInfo: {name: "test", version: "1"}}})
            yield app, sdk, scope, source, fixture
          end
        end.wait
      end
    end
  end

  def invoke(sdk, name, **arguments)
    response = sdk.handle({jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: name, arguments: arguments}})
    JSON.parse(JSON.generate(response)).fetch("result").fetch("structuredContent")
  end

  def wire_ref(ref)
    {"generation" => ref.binding_key, "kind" => ref.kind.to_s, "id" => ref.id}
  end
end
