# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../gems/libtmux/lib/libtmux/source_query"
require_relative "../../gems/libtmux/lib/libtmux/snapshot"

class SourceQueryTest < Minitest::Test
  class Source
    attr_reader :calls

    def initialize(snapshot)
      @snapshot = snapshot
      @calls = []
    end

    def snapshot(**options)
      @calls << options
      @snapshot
    end
  end

  def test_plan_has_no_io_and_local_modes_capture_once_without_restricting_relations
    rows = {window: [{id: "@1"}], pane: [
      {id: "%1", window_id: "@1", index: "0", current_command: "cat"},
      {id: "%2", window_id: "@1", index: "1", current_command: "nvim"}
    ]}
    graph = LibTmux::Snapshot.__send__(:new, rows: rows, binding_key: "binding",
      started_at: 1.0, finished_at: 2.0, reads: [], server_info: {})
    source = Source.new(graph)
    %i[auto never].each do |mode|
      plan = LibTmux::Internal::SourceQuery.new(:pane, where: {current_command: "nvim"}, pushdown: mode)
      before = source.calls.size
      explanation = plan.explain
      assert_nil explanation.fetch(:pushed)
      assert_equal :full_graph, explanation.fetch(:capture)
      assert explanation.frozen?
      assert_equal before, source.calls.size
      result = plan.execute(source, timeout: 0.5)
      assert_equal before + 1, source.calls.size
      assert_equal ["%2"], result.map(&:id)
      assert_equal ["%1", "%2"], result.one.window.panes.map(&:id)
      result.to_a
      result.where(index: 1).one
      assert_equal before + 1, source.calls.size
    end
    refute_empty LibTmux::Internal::SourceQuery.new(:pane, where: {}, pushdown: :auto).explain.fetch(:rejected_optimization_reasons)
  end

  def test_invalid_criteria_and_required_pushdown_are_rejected_before_acquisition
    source = Source.new(nil)
    assert_raises(LibTmux::InvalidFilterError) do
      LibTmux::Internal::SourceQuery.new(:pane, where: {active: "0"}, pushdown: :auto).execute(source)
    end
    assert_raises(ArgumentError) { LibTmux::Internal::SourceQuery.new(:pane, where: {}, pushdown: :sometimes) }
    plan = LibTmux::Internal::SourceQuery.new(:pane, where: {index: {gt: 2}}, pushdown: :required)
    refute plan.explain.fetch(:executable)
    assert_raises(LibTmux::UnsupportedFeatureError) { plan.execute(source) }
    assert_empty source.calls
    private_plan = LibTmux::Internal::SourceQuery.new(:pane, where: {current_path: "private-secret"})
    refute_includes private_plan.inspect, "private-secret"
    assert_raises(LibTmux::InvalidFilterError) do
      LibTmux::Internal::SourceQuery.new(:pane, where: LibTmux::WindowWhere.build({}), pushdown: :never)
    end
  end
end
