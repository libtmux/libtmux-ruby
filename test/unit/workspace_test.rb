# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/workspace"
require "tmpdir"

class WorkspaceTest < Minitest::Test
  def document
    {"session_name" => "work", "windows" => [
      {"window_name" => "editor", "panes" => [{"shell_command" => "printf literal"}, {}]}
    ]}
  end

  def parse(value, **options)
    LibTmux::Workspace.parse(JSON.generate(value), format: :json, base_directory: "/workspace", **options)
  end

  def test_data_only_yaml_and_json_loads_have_one_immutable_normalized_profile
    Dir.mktmpdir("libtmux-ruby-workspace-") do |directory|
      marker = File.join(directory, "must-not-exist")
      source = document
      source["start_directory"] = "project"
      source["windows"][0]["panes"][0]["shell_command"] = "touch #{marker}"
      path = File.join(directory, "workspace.yaml")
      File.write(path, Psych.dump(source))
      yaml = LibTmux::Workspace.load(path)
      json = LibTmux::Workspace.parse(JSON.generate(source), format: :json, base_directory: directory)
      assert_equal yaml.to_h, json.to_h
      assert_equal "libtmux-ruby.workspace", yaml.to_h.fetch("profile")
      assert_equal File.join(directory, "project"), yaml.to_h.fetch("windows").first.fetch("panes").first.fetch("start_directory")
      refute File.exist?(marker)
      assert_raises(FrozenError) { yaml.to_h.fetch("windows").first.fetch("panes").first.fetch("shell_command").first.replace("changed") }
      refute_includes yaml.inspect, marker
    end
  end

  def test_duplicates_tags_aliases_unknown_fields_and_limits_fail_before_planning
    invalid = [
      "session_name: work\nsession_name: other\nwindows: []\n",
      "session_name: !!str work\nwindows: []\n",
      "session_name: &name work\nwindows: [*name]\n",
      "? [complex, key]\n: value\n",
      "---\nsession_name: work\n---\nwindows: []\n"
    ]
    invalid.each do |yaml|
      assert_raises(LibTmux::Workspace::ConfigError) do
        LibTmux::Workspace.parse(yaml, format: :yaml, base_directory: "/workspace")
      end
    end
    assert_raises(LibTmux::Workspace::ConfigError) do
      LibTmux::Workspace.parse('{"session_name":"a","session_name":"b"}', format: :json, base_directory: "/workspace")
    end
    [document.merge("before_script" => "secret-command"), document.merge("private-secret-key" => true),
      document.merge("version" => 1), document.merge("profile" => "foreign", "version" => 1),
      document.merge("windows" => []), document.merge("session_name" => "bad:name")].each do |value|
      error = assert_raises(LibTmux::Workspace::ConfigError) { parse(value) }
      refute_includes error.full_message, "secret"
    end
    assert_raises(LibTmux::Workspace::ConfigError) { parse(document, max_bytes: 16) }
    assert_raises(LibTmux::Workspace::ConfigError) { parse(document, max_panes: 1) }
    nonfile = assert_raises(LibTmux::Workspace::ConfigError) { LibTmux::Workspace.load("/dev/null", format: :yaml) }
    assert_equal "regular configuration file", nonfile.expected
    nested = "a: [" * 40 + "0" + "]" * 40
    assert_raises(LibTmux::Workspace::ConfigError) do
      LibTmux::Workspace.parse(nested, format: :yaml, base_directory: "/workspace")
    end
  end

  def test_inheritance_is_parent_to_child_and_expansion_is_explicit_and_nonshell
    source = document.merge("start_directory" => "${PROJECT}", "environment" => {"A" => "root", "B" => "${VALUE}"},
      "shell_command_before" => ["root-before"])
    window = source.fetch("windows").first
    window.merge!("start_directory" => "window", "environment" => {"A" => "window"}, "shell_command_before" => "window-before")
    pane = window.fetch("panes").first
    pane.merge!("start_directory" => "../pane", "environment" => {"A" => "pane"},
      "shell_command_before" => "pane-before", "shell_command" => "echo ${VALUE}; $(touch ignored)")
    config = parse(source, expand_environment: true, environment: {"PROJECT" => "root", "VALUE" => "literal"}).to_h
    first, second = config.fetch("windows").first.fetch("panes")
    assert_equal "/pane", first.fetch("start_directory")
    assert_equal "/workspace/window", second.fetch("start_directory")
    assert_equal({"A" => "pane", "B" => "literal"}, first.fetch("environment"))
    assert_equal ["root-before", "window-before", "pane-before"], first.fetch("shell_command_before")
    assert_equal ["echo ${VALUE}; $(touch ignored)"], first.fetch("shell_command")
    round_trip = LibTmux::Workspace.parse(JSON.generate(config), format: :json, base_directory: "/elsewhere")
    assert_equal config, round_trip.to_h
    assert_equal ["root-before", "window-before", "pane-before", "echo ${VALUE}; $(touch ignored)"],
      round_trip.plan.steps.select { |step| step.operation == :send_command && step.target == "pane:0:0" }.map { |step| step.arguments.fetch("command") }
    assert_equal "${VALUE}", parse(source).to_h.fetch("environment").fetch("B")
    assert_raises(LibTmux::Workspace::ConfigError) { parse(source, expand_environment: true) }
  end

  def test_indexes_focus_layout_and_typed_scope_options_are_validated
    source = document
    source["windows"] << {"window_name" => "logs", "window_index" => 3, "panes" => ["tail logs"]}
    source["windows"][0].merge!("window_index" => 3)
    assert_raises(LibTmux::Workspace::ConfigError) { parse(source) }
    source["windows"][0]["window_index"] = 0
    source["windows"].each { |window| window["focus"] = true }
    assert_raises(LibTmux::Workspace::ConfigError) { parse(source) }
    source["windows"][1]["focus"] = false
    source["windows"][0]["layout"] = "arbitrary,layout"
    assert_raises(LibTmux::Workspace::ConfigError) { parse(source) }
    source["windows"][0]["layout"] = "tiled"
    source["options"] = {"mouse" => "on"}
    assert_raises(LibTmux::Workspace::ConfigError) { parse(source) }
    source["options"] = {"mouse" => true, "status" => false}
    source["windows"][0]["options"] = {"automatic-rename" => false, "remain-on-exit" => true}
    assert_equal 3, parse(source).to_h.fetch("windows").last.fetch("window_index")
  end

  def test_expansion_and_inheritance_obey_normalized_memory_bounds
    source = document.merge("environment" => {"EXPANDED" => "${BIG}" * 20})
    assert_raises(LibTmux::Workspace::ConfigError) do
      parse(source, expand_environment: true, environment: {"BIG" => "x" * 100}, max_string_bytes: 1024)
    end
    source = document.merge("shell_command_before" => "x" * 200)
    source["windows"][0]["panes"] = Array.new(8) { {} }
    assert_raises(LibTmux::Workspace::ConfigError) { parse(source, max_bytes: 1024) }
    assert_raises(LibTmux::Workspace::ConfigError) do
      parse(document, environment: {"BIG1" => "x" * 700, "BIG2" => "x" * 700}, max_bytes: 1024)
    end
    escaped = document.merge("shell_command_before" => "\u0001" * 50)
    assert_raises(LibTmux::Workspace::ConfigError) { parse(escaped, max_bytes: 1024) }
    yaml = "session_name: work\nenvironment: {NUMBER: 1.5}\nwindows: [{window_name: one, panes: [{}]}]\n"
    assert_raises(LibTmux::Workspace::ConfigError) do
      LibTmux::Workspace.parse(yaml, format: :yaml, base_directory: "/workspace")
    end
  end

  def test_plan_reuses_initial_entities_and_keeps_provenance_without_io
    source = document
    source["windows"][0]["layout"] = "tiled"
    source["windows"] << {"window_name" => "logs", "panes" => [{}]}
    workspace = parse(source)
    offline = workspace.plan
    assert_equal :offline_create, offline.mode
    assert_equal [:create_session, :split_pane, :create_window], offline.steps.select { |step| step.effect == :creation }.map(&:operation)
    assert_equal ["session", "window:0", "pane:0:0"], offline.steps.first.produces
    command = offline.steps.find { |step| step.operation == :send_command }
    assert_equal :dispatch_only, command.effect
    assert_equal "pane:0:0", command.target
    assert offline.frozen?
    assert offline.steps.all?(&:frozen?)
    assert_raises(FrozenError) { offline.steps.first.arguments.fetch("name").replace("changed") }
    graph = LibTmux::Snapshot.send(:new, rows: {session: []}, binding_key: "binding", started_at: 1, finished_at: 2, reads: [], server_info: {})
    live = workspace.plan(snapshot: graph)
    assert_equal :captured_create, live.mode
    assert_equal graph.capture_id, live.preconditions.fetch("capture_id")
    assert_equal "binding", live.preconditions.fetch("binding_key")
    conflict = LibTmux::Snapshot.send(:new, rows: {session: [{id: "$1", name: "work"}]}, binding_key: "binding", started_at: 1, finished_at: 2, reads: [], server_info: {})
    assert_raises(LibTmux::Workspace::ConflictError) { workspace.plan(snapshot: conflict) }
    assert_equal offline.to_h, workspace.plan.to_h
  end
end
