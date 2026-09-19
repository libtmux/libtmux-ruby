# frozen_string_literal: true

require "json"
require "stringio"
require "rbs"
require "rbs/test"
require "rbs/unit_test/spy"

# Explicit call boundaries avoid modifying frozen classes or consuming streams.
class SignatureConsumer
  attr_reader :exercised

  def initialize
    loader = RBS::EnvironmentLoader.new
    %w[libtmux libtmux-async libtmux-mcp libtmux-workspace].each do |name|
      spec = Gem::Specification.find_all_by_name(name).first
      loader.add(path: Pathname(File.join(spec.full_gem_path, "sig"))) if spec
    end
    @builder = RBS::DefinitionBuilder.new(env: RBS::Environment.from_loader(loader).resolve_type_names)
    @exercised = []
  end

  def call(as, receiver, method, *arguments, expected:, **keywords, &block)
    type = RBS::Parser.parse_type(as)
    klass = Object.const_get(type.name.to_s)
    singleton = type.is_a?(RBS::Types::ClassSingleton)
    definition = singleton ? @builder.build_singleton(type.name) : @builder.build_instance(type.name)
    declared = definition.methods.fetch(method) { raise "missing signature: #{as} #{method}" }
    raise "signature is private: #{as} #{method}" unless declared.accessibility == :public
    overloads = declared.defs.map(&:type)
    unless singleton
      substitution = RBS::Substitution.build(definition.type_params, type.args)
      overloads = overloads.map { |entry| entry.sub(substitution) }
    end
    checker = RBS::Test::TypeCheck.new(self_class: singleton ? klass.singleton_class : klass,
      instance_class: klass, class_class: klass.singleton_class, builder: @builder,
      sample_size: nil, unchecked_classes: [])
    spy = RBS::UnitTest::Spy.wrap(receiver, method)
    trace = nil
    spy.callback = ->(value) { trace = value }
    result = spy.wrapped_object.__send__(method, *arguments, **keywords, &block)
    matches = overloads.any? { |entry| checker.method_call(method, entry, trace, errors: []).empty? }
    raise "call violates shipped signature: #{as} #{method}" unless matches
    concrete = RBS::Parser.parse_type(expected)
    if concrete.is_a?(RBS::Types::Bases::Any) || concrete.to_s.include?("Enumerator")
      raise "consumer expectation must be concrete and must not enumerate a stream"
    end
    raise "return violates consumer expectation: #{as} #{method}" unless checker.value(result, concrete)
    @exercised << "#{type.name}#{singleton ? '.' : '#'}#{method}"
    @last = [checker, overloads, method, trace]
    result
  end

  def verify_rejects_wrong_return
    checker, overloads, method, trace = @last
    corrupted = trace.dup
    corrupted.method_call = RBS::Test::ArgumentsReturn.return(arguments: trace.method_call.arguments, value: Object.new)
    if overloads.any? { |entry| checker.method_call(method, entry, corrupted, errors: []).empty? }
      raise "signature checker failed to reject a wrong implementation return"
    end
  end
end

package = ARGV.fetch(0)
imports = {"libtmux" => "libtmux", "libtmux-async" => "libtmux/async",
  "libtmux-mcp" => "libtmux/mcp/cli", "libtmux-workspace" => "libtmux/workspace/cli"}
require imports.fetch(package)
consumer = SignatureConsumer.new

LibTmux::Server.start(executable: ENV.fetch("LIBTMUX_TEST_TMUX", "tmux")) do |server|
  case package
  when "libtmux"
    receipt = consumer.call("::LibTmux::Server", server, :new_session, name: "types", command: ["/bin/cat"], receipt: true,
      expected: "::LibTmux::CreationReceipt")
    session = consumer.call("::LibTmux::CreationReceipt", receipt, :entity, expected: "::LibTmux::Session")
    pane = consumer.call("::LibTmux::CreationReceipt", receipt, :pane, expected: "::LibTmux::Pane")
    consumer.call("::LibTmux::Session", session, :new_window, name: "second", command: ["/bin/cat"], expected: "::LibTmux::Window")
    snapshot = consumer.call("::LibTmux::Server", server, :snapshot, expected: "::LibTmux::Snapshot")
    panes = consumer.call("::LibTmux::Snapshot", snapshot, :panes, expected: "::LibTmux::Selection[::LibTmux::PaneSnapshot]")
    records = consumer.call("::LibTmux::Selection[::LibTmux::PaneSnapshot]", panes, :to_a, expected: "Array[::LibTmux::PaneSnapshot]")
    expression = consumer.call("singleton(::LibTmux::PaneWhere)", LibTmux::PaneWhere, :build, {id: pane.id}, expected: "::LibTmux::FilterExpr")
    selected = consumer.call("::LibTmux::Selection[::LibTmux::PaneSnapshot]", panes, :where, expression,
      expected: "::LibTmux::Selection[::LibTmux::PaneSnapshot]")
    record = consumer.call("::LibTmux::Selection[::LibTmux::PaneSnapshot]", selected, :one, expected: "::LibTmux::PaneSnapshot")
    consumer.call("::LibTmux::PaneSnapshot", record, :active?, expected: "bool")
    consumer.call("::LibTmux::PaneSnapshot", record, :dead_status, expected: "Integer?")
    consumer.call("::LibTmux::PaneSnapshot", record, :current_path, expected: "String?")
    consumer.call("::LibTmux::PaneSnapshot", record, :window, expected: "::LibTmux::WindowSnapshot")
    consumer.call("::LibTmux::Selection[::LibTmux::PaneSnapshot]", panes, :one_or_nil, id: "%4294967294", expected: "nil")
    options = consumer.call("::LibTmux::Session", session, :options, expected: "::LibTmux::Options")
    consumer.call("::LibTmux::Options", options, :set, "@types", true, expected: "::LibTmux::CommandResult")
    option = consumer.call("::LibTmux::Options", options, :get, "@types", expected: "::LibTmux::OptionValue")
    consumer.call("::LibTmux::OptionValue", option, :as, :boolean, expected: "bool")
    result = consumer.call("::LibTmux::Pane", pane, :capture, expected: "::LibTmux::CommandResult")
    consumer.call("::LibTmux::CommandResult", result, :stdout, expected: "String")
    consumer.call("::LibTmux::CommandResult", result, :success?, expected: "bool")
    consumer.verify_rejects_wrong_return
    consumer.call("::LibTmux::Server", server, :open_control, session: session.ref, expected: ":checked") do |control|
      reply = consumer.call("::LibTmux::ControlConnection", control, :exchange, "display-message -p typed", expected: "::LibTmux::GuardedReply")
      blocks = consumer.call("::LibTmux::GuardedReply", reply, :blocks, expected: "Array[::LibTmux::GuardedBlock]")
      consumer.call("::LibTmux::GuardedBlock", blocks.last, :raw, expected: "String")
      stream = consumer.call("::LibTmux::ControlConnection", control, :subscribe, max_events: 2,
        expected: "::LibTmux::ControlSubscription")
      consumer.call("::LibTmux::ControlSubscription", stream, :close, expected: "nil")
      :checked
    end
    consumer.call("singleton(::LibTmux::ControlEvent)", LibTmux::ControlEvent, :new,
      kind: :output, raw: "%output %0 typed\n", data: "typed", expected: "::LibTmux::ControlEvent")
    raise "consumer fixture unexpectedly empty" unless records.length == 2
  when "libtmux-async"
    session = server.new_session(name: "async-types", command: ["/bin/cat"])
    Async do |parent|
      consumer.call("singleton(::LibTmux::Async)", LibTmux::Async, :open, parent: parent, server: server, expected: ":checked") do |scope|
        facade = consumer.call("::LibTmux::Async::Scope", scope, :server, expected: "::LibTmux::Async::Server")
        panes = consumer.call("::LibTmux::Async::Server", facade, :list_panes, expected: "Array[::LibTmux::Pane]")
        consumer.call("::LibTmux::Async::Scope", scope, :map, panes, concurrency: 2, expected: "Array[::LibTmux::CommandResult]") { |pane| pane.capture }
        consumer.call("::LibTmux::Async::Server", facade, :open_control, session: session.ref, expected: ":checked") do |control|
          consumer.call("::LibTmux::Async::ControlConnection", control, :exchange, "display-message -p typed", expected: "::LibTmux::GuardedReply")
          :checked
        end
        :checked
      end
    end.wait
  when "libtmux-workspace"
    config = {session_name: "workspace-types", windows: [{window_name: "one", panes: [{}]}]}
    workspace = consumer.call("singleton(::LibTmux::Workspace)", LibTmux::Workspace, :parse,
      JSON.generate(config), format: :json, base_directory: Dir.pwd, expected: "::LibTmux::Workspace")
    plan = consumer.call("::LibTmux::Workspace", workspace, :plan, expected: "::LibTmux::Workspace::Plan")
    consumer.call("::LibTmux::Workspace::Plan", plan, :steps, expected: "Array[::LibTmux::Workspace::Plan::Step]")
    result = consumer.call("::LibTmux::Workspace::Plan", plan, :apply, server: server, expected: "::LibTmux::Workspace::ApplyResult")
    consumer.call("::LibTmux::Workspace::ApplyResult", result, :created_refs, expected: "Hash[String, ::LibTmux::EntityRef]")
    effects = consumer.call("::LibTmux::Workspace::ApplyResult", result, :effects, expected: "Array[::LibTmux::Workspace::ApplyResult::Effect]")
    effect = effects.first
    type = LibTmux::Workspace::ApplyResult::Effect
    consumer.call("singleton(::LibTmux::Workspace::ApplyResult::Effect)", type, :new,
      step_id: effect.step_id, action: effect.action, outcome: effect.outcome, expected: "::LibTmux::Workspace::ApplyResult::Effect")
    consumer.call("singleton(::LibTmux::Workspace::ApplyResult::Effect)", type, :[],
      effect.step_id, effect.action, effect.outcome, expected: "::LibTmux::Workspace::ApplyResult::Effect")
    consumer.call("singleton(::LibTmux::Workspace::ApplyResult::Effect)", type, :members, expected: "Array[Symbol]")
    step = plan.steps.first
    type = LibTmux::Workspace::Plan::Step
    consumer.call("singleton(::LibTmux::Workspace::Plan::Step)", type, :[], step.id, step.operation, step.target,
      step.arguments, step.produces, step.effect, expected: "::LibTmux::Workspace::Plan::Step")
    consumer.call("singleton(::LibTmux::Workspace::Plan::Step)", type, :members, expected: "Array[Symbol]")
    consumer.call("singleton(::LibTmux::Workspace::CLI)", LibTmux::Workspace::CLI, :run, ["--help"],
      out: StringIO.new, err: StringIO.new, expected: "Integer")
  when "libtmux-mcp"
    server.new_session(name: "mcp-types", command: ["/bin/cat"])
    Async do |parent|
      LibTmux::Async.open(parent: parent, server: server) do |scope|
        app = consumer.call("singleton(::LibTmux::MCP::Application)", LibTmux::MCP::Application, :new,
          server: scope.server, endpoint_name: "types", expected: "::LibTmux::MCP::Application")
        consumer.call("::LibTmux::MCP::Application", app, :tools, expected: "Array[singleton(::MCP::Tool)]")
        consumer.call("::LibTmux::MCP::Application", app, :sdk_server, expected: "::MCP::Server")
        consumer.call("::LibTmux::MCP::Application", app, :call, "tmux_snapshot", {"entity" => "pane"}, expected: "::MCP::Tool::Response")
      end
    end.wait
    consumer.call("singleton(::LibTmux::MCP::CLI)", LibTmux::MCP::CLI, :run, ["--help"],
      out: StringIO.new, err: StringIO.new, expected: "Integer")
  end
end

if ENV["LIBTMUX_EXAMPLE_INSTALLED"]
  own = $LOADED_FEATURES.select { |feature| feature.include?("/libtmux/") || feature.end_with?("/libtmux.rb") }
  raise "consumer loaded repository source" unless own.all? { |feature| feature.start_with?(ENV.fetch("GEM_HOME") + "/") }
end
puts JSON.generate({"package" => package, "exercised" => consumer.exercised.uniq.sort,
  "proof" => "observed arguments, blocks and returns", "whole_program_static_check" => false})
