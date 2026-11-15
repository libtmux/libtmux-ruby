# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmuxp_catalog"

# tmuxp's example catalog, loaded through LibTmux::Workspace.load. Each file is
# loaded or refused as recorded, each loaded file produces the structure written
# by hand in test/fixtures/tmuxp/expected, and the record of tmuxp syntax in
# test/fixtures/tmuxp/syntax-support.json matches what the loader does. No test
# here starts tmux or tmuxp; test/integration/workspace_tmuxp_test.rb builds the
# loaded files on a real tmux.
class WorkspaceTmuxpTest < Minitest::Test
  Catalog = LibTmuxTest::TmuxpCatalog

  def test_every_tmuxp_example_is_classified
    found = Catalog.children
    assert_equal found, (Catalog::LOADED + Catalog::REFUSED.keys).sort
    assert_operator found.size, :>=, 20
  end

  def test_tmuxp_examples_load_through_workspace_load
    Catalog::LOADED.each do |name|
      assert_equal "libtmux-ruby.workspace", Catalog.workspace(name).to_h.fetch("profile"), name
    end
  end

  def test_tmuxp_examples_the_loader_refuses_fail_as_recorded
    Catalog::REFUSED.each do |name, message|
      error = assert_raises(LibTmux::Workspace::ConfigError, name) { Catalog.workspace(name) }
      assert_equal message, error.message, name
    end
  end

  def test_each_loaded_example_has_one_expected_structure
    expected = Dir.children(Catalog::EXPECTED).sort
    assert_equal Catalog::LOADED.map { |name| name.sub(/\.yaml\z/, ".json") }.sort, expected
    Catalog::LOADED.each { |name| assert_equal %w[session source windows].sort, Catalog.expected(name).keys.sort, name }
  end

  def test_each_loaded_example_produces_the_structure_tmuxp_documents_for_it
    Catalog::LOADED.each do |name|
      assert_equal Catalog.port_expected(name), Catalog.structure(Catalog.workspace(name), name), name
    end
  end

  # The differences are the loader's, not slips in the files: a file that came
  # out as tmuxp has it would mean the difference was gone, and its entry stale.
  def test_every_recorded_difference_still_differs_from_tmuxp
    Catalog::LOADED.each do |name|
      refute_equal Catalog.expected(name).merge("source" => nil), Catalog.structure(Catalog.workspace(name), name), name
    end
    Catalog::DIFFERENCES.each do |name, differences|
      differences.each do |difference|
        refute_equal difference.fetch(:from), difference.fetch(:to), "#{name}: #{difference.fetch(:rule)}"
        assert_equal difference.fetch(:from), Catalog.expected(name).dig(*difference.fetch(:path), "start_directory")
      end
    end
  end

  def test_the_comparison_reports_a_wrong_structure
    loaded = Catalog.structure(Catalog.workspace("3-pane.yaml"), "3-pane.yaml")
    assert_equal Catalog.port_expected("3-pane.yaml"), loaded
    {"another file" => Catalog.port_expected("4-pane.yaml"),
     "a layout" => Catalog.port_expected("3-pane.yaml").tap { |tree| tree["windows"][0]["layout"] = "tiled" },
     "a focus" => Catalog.port_expected("3-pane.yaml").tap { |tree| tree["windows"][0]["panes"][1]["focus"] = true },
     "a command" => Catalog.port_expected("3-pane.yaml").tap { |tree| tree["windows"][0]["panes"][2]["commands"] << "x" },
     "a directory" => Catalog.port_expected("3-pane.yaml").tap { |tree| tree["windows"][0]["panes"][0]["start_directory"] = "/tmp" }}.each do |change, wrong|
      refute_equal wrong, loaded, change
    end
  end

  def parse(entry)
    options = (entry["options"] || {}).transform_keys(&:to_sym)
    LibTmux::Workspace.parse(entry.fetch("probe").join("\n") + "\n", format: :yaml, base_directory: "/workspace", **options)
  end

  def test_the_syntax_record_matches_what_the_loader_does
    record = Catalog.syntax
    entries = record.fetch("entries")
    assert_equal record.fetch("statuses").keys.sort, entries.map { |entry| entry.fetch("status") }.uniq.sort
    assert_equal entries.map { |entry| entry.fetch("id") }, entries.map { |entry| entry.fetch("id") }.uniq
    entries.each do |entry|
      id = entry.fetch("id")
      case entry.fetch("status")
      when "supported"
        assert parse(entry), id
        refute entry.key?("message") || entry.key?("difference"), id
      when "difference"
        model = parse(entry).to_h
        observed = entry.fetch("observed")
        assert_equal observed.fetch("value"), model.dig(*observed.fetch("path")), id
        refute_empty entry.fetch("difference"), id
      when "refused"
        error = assert_raises(LibTmux::Workspace::ConfigError, id) { parse(entry) }
        assert_equal entry.fetch("message"), error.message, id
      else flunk "#{id}: unknown status"
      end
    end
  end

  def test_the_syntax_record_names_every_tmuxp_key_the_catalog_uses
    keys = Catalog.syntax.fetch("entries").map { |entry| entry.fetch("key") }
    %w[session_name start_directory environment shell_command_before before_script global_options options plugins window_name
       layout window_index focus options_after window_shell suppress_history panes shell_command enter sleep_before sleep_after shell].each do |key|
      assert_includes keys, key
    end
    used = Catalog.children.flat_map { |name| File.read(Catalog.path(name)).scan(/^\s*(?:-\s+)?([a-z_]+):/).flatten }.uniq
    assert_empty used - keys - %w[cmd], "keys in the catalog the record does not name"
  end

  def test_a_changed_loader_fails_the_record
    entry = Catalog.syntax.fetch("entries").find { |candidate| candidate.fetch("id") == "before-script" }
    accepted = entry.merge("probe" => ["session_name: a", "windows:", "  - window_name: w", "    panes: [{}]"])
    assert_raises(Minitest::Assertion) do
      assert_raises(LibTmux::Workspace::ConfigError) { parse(accepted) }
    end
    entry = Catalog.syntax.fetch("entries").find { |candidate| candidate.fetch("id") == "start-directory-tilde" }
    wrong = entry.merge("observed" => {"path" => ["start_directory"], "value" => "/home/u/x"})
    refute_equal wrong.dig("observed", "value"), parse(wrong).to_h.dig(*wrong.dig("observed", "path"))
  end
end
