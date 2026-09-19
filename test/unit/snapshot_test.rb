# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"
require "libtmux/snapshot" if File.exist?(File.expand_path("../../gems/libtmux/lib/libtmux/snapshot.rb", __dir__))

class SnapshotTest < Minitest::Test
  def test_graph_owns_values_orders_numeric_ids_and_retains_link_occurrences
    rows = graph_rows
    name = rows.fetch(:session).first.fetch(:name)
    capture = build(rows)
    name.replace("changed")
    rows.fetch(:pane).clear

    assert capture.frozen?
    assert_equal ["@2", "@10"], capture.windows.map(&:id)
    assert_equal ["%2", "%10"], capture.panes.map(&:id)
    session = capture.sessions.one
    assert_equal "session", session.name
    assert session.name.frozen?
    assert_equal [2, 5, 10], session.window_links.map(&:index)
    assert_equal ["@2", "@2", "@10"], session.windows.map(&:id)
    assert_same session.windows.first, session.windows.to_a.fetch(1)
    assert_equal ["%10", "%2"], capture.windows.first.panes.map(&:id)
    assert_equal 2, capture.windows.first.window_links.size
    assert_same capture.windows.first, capture.panes.first.window
    assert_same capture.panes.first, capture.windows.first.active_pane
    assert_same capture.windows.first, session.current_window
    assert_same session, session.window_links.first.session
    assert_same capture.windows.first, session.window_links.first.window
    assert_equal 2, capture.panes.select { |pane| pane.id == "%2" }.one.window.panes.size
    refute_respond_to capture.windows.first, :index
    refute_respond_to capture.windows.first, :session
    refute_respond_to capture.windows.first, :active?
    assert capture.panes.first.active?
    assert capture.panes.first.raw(:title).frozen?
    assert_equal Encoding::BINARY, capture.panes.first.raw(:title).encoding
  end

  def test_record_equality_is_capture_scoped_and_refs_are_binding_scoped
    first = build(graph_rows)
    second = build(graph_rows)
    foreign = build(graph_rows, binding_key: "different")
    refute_equal first.panes.first, second.panes.first
    assert_equal first.panes.first.ref, second.panes.first.ref
    refute_equal first.panes.first.ref, foreign.panes.first.ref
    assert_same first.panes.first, first.resolve(second.panes.first.ref)
    assert_raises(LibTmux::TargetNotFoundError) { first.resolve(foreign.panes.first.ref) }
    assert_equal 3, first.window_links.map(&:ref).uniq.size
    assert_same first.window_links.first, first.resolve(first.window_links.first.ref)
  end

  def test_conflicting_rows_broken_edges_and_duplicate_placement_are_refused
    rows = graph_rows
    rows[:window] << rows[:window].first.merge(name: "conflict")
    assert_raises(LibTmux::InconsistentSnapshotError) { build(rows) }
    rows = graph_rows
    rows[:pane].first[:window_id] = "@404"
    assert_raises(LibTmux::InconsistentSnapshotError) { build(rows) }
    rows = graph_rows
    rows[:window_link] << rows[:window_link].first.merge(window_id: "@2")
    assert_raises(LibTmux::InconsistentSnapshotError) { build(rows) }
    rows = graph_rows
    rows[:window] << rows[:window].first.dup
    rows[:pane] << rows[:pane].first.dup
    assert_equal 2, build(rows).windows.size
  end

  def test_invalid_text_keeps_raw_bytes_without_hiding_unrelated_fields
    rows = graph_rows
    rows[:pane].first[:title] = "bad\xFF\n:#{123}".b
    capture = build(rows)
    pane = capture.panes.first
    assert_equal 4, pane.index
    assert_equal "bad\xFF\n:123".b, pane.raw(:title)
    error = assert_raises(LibTmux::FieldDecodeError) { pane.title }
    refute_includes error.message, "bad"
    assert_equal :complete, pane.__send__(:field_coverage, :title)
    rows = graph_rows
    rows[:pane].first[:index] = "2.0"
    assert_raises(LibTmux::FieldDecodeError) { build(rows) }
    rows[:pane].first[:index] = "4294967296"
    assert_raises(LibTmux::FieldDecodeError) { build(rows) }
    rows[:pane].first[:index] = "2"
    rows[:pane].first[:active] = "true"
    assert_raises(LibTmux::FieldDecodeError) { build(rows) }
  end

  def test_coverage_distinguishes_absent_empty_unloaded_incomplete_and_unsupported
    full = build(graph_rows)
    assert_nil full.panes.first.dead_status
    empty = build({session: [], window: [], pane: [], window_link: []})
    assert_empty empty.panes
    partial = build({pane: [{id: "%1", window_id: "@1", index: "0"}]})
    pane = partial.panes.one
    assert_equal :unloaded, pane.__send__(:field_coverage, :title)
    assert_equal :unloaded, pane.__send__(:relation_coverage, :window)
    assert_raises(LibTmux::IncompleteSnapshotError) { pane.window }
    assert_raises(LibTmux::IncompleteSnapshotError) { pane.title }
    assert_raises(LibTmux::IncompleteSnapshotError) { partial.windows }
    unavailable = build(graph_rows, coverage: {pane: {fields: {title: :unsupported}}, window: {relations: {panes: :incomplete}}})
    assert_raises(LibTmux::UnsupportedFeatureError) { unavailable.panes.first.title }
    assert_raises(LibTmux::IncompleteSnapshotError) { unavailable.windows.first.panes }
    no_children = build({window: [{id: "@0"}], pane: []})
    assert_nil no_children.windows.one.active_pane
  end

  def test_catalog_is_explicit_typed_and_deeply_frozen
    build(graph_rows)
    catalog = LibTmux::Internal::Catalog
    field = catalog.entity(:pane).fields.fetch(:current_command)
    assert_equal "currentCommand", field.wire_name
    assert_equal "pane.current_command", field.id
    assert_equal "pane_current_command", field.format
    assert_equal :text, field.type
    assert field.frozen?
    assert field.operators.frozen?
    assert catalog.entity(:pane).fields.frozen?
    assert_equal 255, catalog.entity(:pane).fields.fetch(:dead_status).max
    refute catalog.entity(:window).fields.key?(:index)
    refute catalog.entity(:window).relations.key?(:session)
    # Nullability alone must not turn a legitimate empty text value into absence.
    optional_text = catalog.entity(:pane).fields.fetch(:title).with(nullable: true)
    assert_equal "", build(graph_rows).panes.first.__send__(:decode, optional_text, "".b)
  end

  def test_declared_coverage_cannot_invent_missing_values_or_relations
    partial = build({pane: [{id: "%1", window_id: "@1", index: "0"}]},
      coverage: {pane: {fields: {title: :complete}, relations: {window: :complete}}})
    pane = partial.panes.one
    assert_equal :unloaded, pane.__send__(:field_coverage, :title)
    assert_equal :unloaded, pane.__send__(:relation_coverage, :window)
    assert_raises(LibTmux::IncompleteSnapshotError) { pane.title }
    assert_raises(LibTmux::IncompleteSnapshotError) { pane.window }
    observed = build({client: [{name: "control", pid: "1", created: "2", session_id: ""}]})
    assert_nil observed.clients.one.session
    assert_raises(LibTmux::UnsupportedFeatureError) { observed.clients.one.ref }
    per_record = build(graph_rows, coverage: {pane: {records: {"%2" => {fields: {title: :unsupported}}}}})
    assert_raises(LibTmux::UnsupportedFeatureError) { per_record.panes.first.title }
    assert_equal "sibling", per_record.panes.to_a.last.title
  end

  private

  def build(rows, **options)
    assert defined?(LibTmux::Snapshot), "captured graph is not implemented"
    LibTmux::Snapshot.__send__(:new, rows: rows, binding_key: "binding", started_at: 1.0,
      finished_at: 2.0, reads: [], server_info: {}, **options)
  end

  def graph_rows
    {
      session: [{id: "$2", name: +"session", window_count: "3"}],
      window: [{id: "@10", name: "second", pane_count: "0"}, {id: "@2", name: "shared", pane_count: "2"}],
      pane: [
        {id: "%2", window_id: "@2", index: "4", title: "title", active: "1", dead_status: ""},
        {id: "%10", window_id: "@2", index: "0", title: "sibling", active: "0", dead_status: ""}
      ],
      window_link: [
        {session_id: "$2", window_id: "@10", index: "10", active: "0"},
        {session_id: "$2", window_id: "@2", index: "5", active: "0"},
        {session_id: "$2", window_id: "@2", index: "2", active: "1"}
      ]
    }
  end
end
