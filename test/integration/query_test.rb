# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"

class QueryIntegrationTest < Minitest::Test
  def test_explicit_source_queries_match_local_captures_and_keep_complete_relations
    source_type = Class.new(LibTmux::Server) do
      attr_reader :calls

      def run(...)
        @calls = (@calls || 0) + 1
        super
      end
    end
    LibTmuxTest::TmuxFixture.open do |fixture|
      source_type.open(socket_path: fixture.socket_path) do |server|
        window = server.list_windows.fetch(0)
        window.split(direction: :horizontal, command: ["/bin/cat"])
        before = server.calls
        explanation = server.explain_panes(where: {index: {gte: 1}}, pushdown: :auto)
        assert_equal before, server.calls
        assert_nil explanation.fetch(:pushed)
        assert_raises(LibTmux::UnsupportedFeatureError) { server.search_panes(where: {}, pushdown: :required) }
        assert_raises(LibTmux::InvalidFilterError) { server.search_panes(where: {active: "0"}) }
        assert_equal before, server.calls

        expression = LibTmux::PaneWhere.build(index: {gte: 1})
        local = server.snapshot.panes.where(expression)
        result = server.search_panes(where: LibTmux::FilterExpr.from_json(expression.to_json), pushdown: :auto)
        assert_equal local.map(&:ref), result.map(&:ref)
        assert_equal [0, 1], result.one.window.panes.map(&:index)
        assert_equal local.map(&:ref), server.search_panes(where: expression, pushdown: :never).map(&:ref)
        reads = server.calls
        assert result.one.active? == true || result.one.active? == false
        result.one.window.panes.select(&:active?).one
        result.map(&:title)
        result.where(index: {in: [1]}).exists?
        assert_equal reads, server.calls
        server.close
        assert_equal [0, 1], result.one.window.panes.map(&:index)
      end
    end
  end
end
