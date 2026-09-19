# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../gems/libtmux/lib/libtmux/criteria"
require_relative "../../gems/libtmux/lib/libtmux/selection"
require_relative "../../gems/libtmux/lib/libtmux/snapshot"

class CriteriaTest < Minitest::Test
  # Explicit field/edge coverage lets these cases isolate evaluation from I/O.
  Record = Struct.new(:kind, :values, :edges, :coverage) do
    private

    def entity_kind = kind
    def read_field(name) = values.fetch(name)
    def read_relation(name) = edges.fetch(name)
    def field_coverage(name) = coverage.fetch(name, values.key?(name) ? :complete : :unloaded)
    def relation_coverage(name) = coverage.fetch(name, edges.key?(name) ? :complete : :unloaded)
  end

  def pane(**values)
    Record.new(:pane, {id: "%1", index: 0, active: false, current_command: "cat"}.merge(values), {}, {})
  end

  def panes(*records)
    LibTmux::Selection.new(records, entity: :pane)
  end

  def test_empty_and_inactive_branches_still_validate_the_entire_schema
    empty = panes
    [nil, {typo: true}, {active: "0"}, {index: 1.0}, {current_command: /cat/},
      {or: [{}, {index: {contains: "1"}}]}, {current_command: {regex: "cat"}}].each do |query|
      assert_raises(LibTmux::InvalidFilterError) { empty.where(query) }
    end
    error = assert_raises(LibTmux::InvalidFilterError) { empty.where(or: [{}, {active: "0"}]) }
    assert_equal :pane, error.entity
    assert_equal "$.or[1].active.equals", error.path
    refute_match "private-secret", error.message
    assert_raises(ArgumentError) { empty.where({}, active: true) }
    assert_raises(ArgumentError) { empty.where { true } }
    assert_raises(ArgumentError) { empty.filter(active: true) }
    assert_raises(LibTmux::InvalidFilterError) { LibTmux::FilterExpr.build(:missing, {}) }
  end

  def test_scalar_boolean_and_cardinality_semantics
    a, b = pane(index: 2, current_command: "nvim", active: true), pane(index: 12)
    selection = panes(a, b)
    assert_same a, selection.one(current_command: "nvim")
    assert_nil selection.one_or_nil(current_command: "missing")
    assert selection.exists?(active: false)
    assert_equal [b], selection.where(index: {gt: 3, lte: 12}).to_a
    assert_equal [a], selection.where(current_command: {starts_with: "nv", ends_with: "im", contains: "vi"}).to_a
    assert_equal [b], selection.where(index: {not: {in: [1, 2]}}).to_a
    assert_equal [a, b], selection.where(and: []).to_a
    assert_empty selection.where(or: [])
    assert_empty selection.where(not: {})
    assert_equal [a], selection.where(or: [{active: true}, {index: 99}]).to_a
    assert_equal [b], selection.where(not: {active: true}).to_a
    assert_raises(LibTmux::MultipleMatchesError) { panes(a, a).one(active: true) }
  end

  def test_aliases_are_explicit_and_conflicts_are_rejected
    a = pane(current_command: "nvim")
    assert_same a, panes(a).one("currentCommand" => "nvim")
    assert_same a, panes(a).one("current_command" => {"startsWith" => "nv"})
    assert_raises(LibTmux::InvalidFilterError) do
      panes(a).where(current_command: "cat", "currentCommand" => "nvim")
    end
    assert_raises(LibTmux::InvalidFilterError) { panes(a).where(current_command: {starts_with: "a", "startsWith" => "b"}) }
  end

  def test_immutable_expression_composition_and_callable_protocols
    input = {current_command: {in: [+"cat"]}}
    expression = LibTmux::PaneWhere.build(input)
    input[:current_command][:in].first.replace("mutated")
    input.clear
    a, b = pane, pane(current_command: "nvim", active: true)
    assert expression.call(a)
    assert expression === a
    assert_equal [a], [a, b].select(&expression)
    assert expression.and(LibTmux::PaneWhere.build(active: false)).call(a)
    assert expression.or(LibTmux::PaneWhere.build(active: true)).call(b)
    assert expression.not.call(b)
    assert_raises(LibTmux::InvalidFilterError) { expression.and(->(_) { true }) }
    assert_raises(LibTmux::InvalidFilterError) { expression.or(LibTmux::WindowWhere.build({})) }
    assert_raises(LibTmux::InvalidFilterError) { expression.call(Record.new(:window, {}, {}, {})) }
    assert expression.frozen?
  end

  def test_correlated_children_and_unmodified_graph_relations
    a, b = pane(active: true), pane(index: 1, current_command: "nvim")
    window = Record.new(:window, {id: "@1"}, {panes: [a, b]}, {})
    windows = LibTmux::Selection.new([window], entity: :window)
    assert_empty windows.where(panes: {some: {active: true, current_command: "nvim"}})
    assert_equal [window], windows.where(panes: {some: {active: true}}).where(panes: {some: {current_command: "nvim"}}).to_a
    assert_equal [a, b], window.edges[:panes]
    empty = Record.new(:window, {}, {panes: []}, {})
    selection = LibTmux::Selection.new([empty], entity: :window)
    assert_empty selection.where(panes: {some: {active: true}})
    assert_equal [empty], selection.where(panes: {every: {active: true}}).to_a
    assert_equal [empty], selection.where(panes: {none: {active: true}}).to_a
  end

  def test_preflight_cannot_hide_missing_evidence_behind_short_circuit
    a = pane
    a.coverage[:current_command] = :unsupported
    [ {active: true, current_command: "cat"}, {or: [{}, {current_command: "cat"}]},
      {not: {active: true, current_command: "cat"}} ].each do |query|
      assert_raises(LibTmux::IncompleteSnapshotError) { panes(a).where(query) }
    end
    b = pane
    b.coverage[:active] = :incomplete
    window = Record.new(:window, {id: "@1"}, {panes: [pane, b]}, {})
    selection = LibTmux::Selection.new([window], entity: :window)
    assert_raises(LibTmux::IncompleteSnapshotError) { selection.where(panes: {some: {active: false}}) }
    window.coverage[:panes] = :unloaded
    error = assert_raises(LibTmux::IncompleteSnapshotError) { selection.where(panes: {none: {}}) }
    assert_equal :window, error.entity
    assert_equal "$.panes", error.path
    assert_equal "complete captured relation", error.expected
    window.coverage[:panes] = :complete
    window.edges[:panes] = []
    assert_equal [window], selection.where(panes: {none: {active: true}}).to_a
  end

  def test_nullable_fields_and_relations_distinguish_absence_from_unloaded
    absent, present = pane(dead_status: nil, current_path: nil), pane(dead_status: 0, current_path: "")
    assert_equal [absent], panes(absent, present).where(dead_status: nil).to_a
    assert_equal [present], panes(absent, present).where(dead_status: {not: nil}).to_a
    assert_equal [absent], panes(absent, present).where(current_path: nil).to_a
    assert_equal [present], panes(absent, present).where(current_path: "").to_a
    assert_raises(LibTmux::InvalidFilterError) { panes.where(active: nil) }
    assert_raises(LibTmux::InvalidFilterError) { panes.where(dead_status: {gt: nil}) }
    assert_raises(LibTmux::InvalidFilterError) { panes.where(window: {is: nil}) }
    empty = Record.new(:window, {}, {active_pane: nil}, {})
    full = Record.new(:window, {}, {active_pane: pane(active: true)}, {})
    windows = LibTmux::Selection.new([empty, full], entity: :window)
    assert_equal [empty], windows.where(active_pane: {is: nil}).to_a
    assert_equal [full], windows.where(active_pane: {is_not: nil}).to_a
    assert_equal [empty], windows.where(active_pane: {is_not: {active: true}}).to_a
    empty.coverage[:active_pane] = :unloaded
    assert_raises(LibTmux::IncompleteSnapshotError) { windows.where(active_pane: {is: nil}) }
  end

  def test_text_is_exact_utf8_and_serialized_values_do_not_mutate_expressions
    a, b = pane(current_command: "é"), pane(current_command: "e\u0301")
    assert_equal [a], panes(a, b).where(current_command: "é").to_a
    assert_empty panes(pane(current_command: "NVIM")).where(current_command: "nvim")
    assert_raises(LibTmux::InvalidFilterError) { panes.where(current_command: "\xff".b) }
    expression = LibTmux::PaneWhere.build(current_command: {in: ["cat"]})
    wire = expression.to_h
    wire.fetch("where").fetch("currentCommand").fetch("in").first.replace("changed")
    assert expression.call(pane)
    assert_equal [a], panes(a, b).select { |item| item.equal?(a) }.where(current_command: "é").to_a
    assert_raises(LibTmux::InvalidFilterError) do
      LibTmux::FilterExpr.from_json('{"profile":"libtmux-ruby.where","version":1,"entity":"pane","where":{"active":true,"\\u0061ctive":false}}')
    end
    assert_raises(LibTmux::InvalidFilterError) { LibTmux::PaneWhere.build(or: Array.new(2049) { {} }) }
    error = assert_raises(LibTmux::InvalidFilterError) { LibTmux::FilterExpr.from_json('{"private-secret":invalid}') }
    assert_nil error.cause
    refute_includes error.full_message, "private-secret"
  end

  def test_captured_graph_decoding_and_per_record_coverage_preflight
    rows = {pane: [
      {id: "%1", window_id: "@1", index: "0", active: "0", title: "private\xff".b},
      {id: "%2", window_id: "@1", index: "1", active: "1", title: "valid"}
    ]}
    graph = LibTmux::Snapshot.__send__(:new, rows: rows, binding_key: "binding",
      started_at: 1.0, finished_at: 2.0, reads: [], server_info: {})
    assert_equal ["%1"], graph.panes.where(index: 0).map(&:id)
    assert_equal ["%1"], graph.panes.select { |item| item.raw(:title).include?("\xff".b) }.map(&:id)
    error = assert_raises(LibTmux::FieldDecodeError) { graph.panes.where(active: true, title: "valid") }
    assert_equal :pane, error.entity
    assert_equal "$.title", error.path
    refute_includes error.message, "private"
    assert_raises(LibTmux::IncompleteSnapshotError) { graph.panes.where(index: 99, window: {is: {name: "missing"}}) }
    rows[:window] = [{id: "@1"}]
    coverage = {pane: {records: {"%2" => {fields: {active: :incomplete}}}}}
    partial = LibTmux::Snapshot.__send__(:new, rows: rows, binding_key: "binding",
      started_at: 1.0, finished_at: 2.0, reads: [], server_info: {}, coverage: coverage)
    assert_raises(LibTmux::IncompleteSnapshotError) { partial.windows.where(panes: {some: {active: false}}) }
    assert_equal 2, partial.panes.where(index: {gte: 0}).first.window.panes.size
  end

  def test_wire_round_trip_rejects_duplicates_foreign_profiles_and_bounds
    expr = LibTmux::PaneWhere.build(current_command: {starts_with: "nv"}, index: {gte: 2})
    wire = expr.to_json
    assert_includes wire, '"profile":"libtmux-ruby.where"'
    assert_includes wire, '"currentCommand"'
    assert_includes wire, '"startsWith"'
    loaded = LibTmux::FilterExpr.from_json(wire)
    assert_equal expr.to_h, loaded.to_h
    assert_equal expr.to_h, JSON.parse(JSON.generate(expr))
    assert loaded.call(pane(current_command: "nvim", index: 12))
    [wire.sub("libtmux-ruby.where", "libtmux.where"), wire.sub('"version":1', '"version":2'),
      wire.sub('"version":1', '"version":1,"version":1'),
      wire.sub('"currentCommand":', '"currentCommand":"cat","currentCommand":'),
      wire.sub('"currentCommand":', '"current_command":'),
      wire.sub('"startsWith":', '"starts_with":'),
      wire.sub('"where":', '"extension":true,"where":')].each do |invalid|
      assert_raises(LibTmux::InvalidFilterError) { LibTmux::FilterExpr.from_json(invalid) }
    end
    assert_raises(LibTmux::InvalidFilterError) { LibTmux::PaneWhere.build(index: {in: Array.new(1025, 1)}) }
    assert_raises(LibTmux::InvalidFilterError) { LibTmux::PaneWhere.build(current_command: "x" * 65_537) }
    assert_raises(LibTmux::InvalidFilterError) { LibTmux::PaneWhere.build(index: -1) }
    query = {}
    40.times { query = {not: query} }
    assert_raises(LibTmux::InvalidFilterError) { LibTmux::PaneWhere.build(query) }
  end

  def test_diagnostics_redact_operands_and_serialization_respects_wire_limits
    expression = LibTmux::PaneWhere.build(current_path: "private-secret")
    refute_includes expression.inspect, "private-secret"
    large = LibTmux::PaneWhere.build(title: "\0" * 65_536)
    assert_raises(LibTmux::InvalidFilterError) { large.to_json }
    assert large.call(pane(title: "\0" * 65_536))
  end
end
