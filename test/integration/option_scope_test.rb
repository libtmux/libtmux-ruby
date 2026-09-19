# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"

class OptionScopeTest < Minitest::Test
  def test_builtin_inheritance_and_array_cardinality_preserve_scope_and_empty_values
    with_server do |server|
      session = server.list_sessions.first
      window = session.list_windows.first
      pane = window.list_panes.first
      server.options.set("escape-time", 7)
      assert_equal 7, server.options.get("escape-time").as(:integer)
      server.options(scope: :window).set("automatic-rename", false)
      inherited = window.options.get("automatic-rename")
      assert_equal false, inherited.as(:boolean)
      assert inherited.inherited?
      window.options.set("remain-on-exit", true)
      assert pane.options.get("remain-on-exit").inherited?
      assert_equal true, pane.options.get("remain-on-exit").as(:boolean)
      pane.options.set("remain-on-exit", false)
      refute pane.options.get("remain-on-exit").inherited?
      assert_equal false, pane.options.get("remain-on-exit").as(:boolean)
      pane.options.unset("remain-on-exit")
      assert_equal true, pane.options.get("remain-on-exit").as(:boolean)

      session.options.set("@empty", "")
      value = session.options.get("@empty")
      assert value.present?
      refute value.array?
      assert_equal "", value.raw
      session.options.set("update-environment", "")
      empty = session.options.get("update-environment")
      assert empty.array?
      refute empty.present?
      assert_nil empty.index
      assert_equal "", empty.raw
      session.options.set("update-environment", "ONE", index: 3)
      session.options.set("update-environment", "NINE", index: 9)
      assert_raises(LibTmux::MultipleMatchesError) { session.options.get("update-environment") }
      missing = assert_raises(LibTmux::NoMatchError) { session.options.get("update-environment", index: 42) }
      assert_equal :observed, missing.delivery
      session.options.set("update-environment", "", index: 42)
      present_empty = session.options.get("update-environment", index: 42)
      assert present_empty.present?
      assert_equal "", present_empty.raw
      session.options.unset("update-environment", index: 42)
      session.options.set("update-environment", "TEN ELEVEN", append: true)
      assert_equal [[0, "TEN"], [1, "ELEVEN"], [3, "ONE"], [9, "NINE"]], session.options.list(name: "update-environment").map { |entry| [entry.index, entry.raw] }
      session.options.unset("update-environment", index: 9)
      assert_equal [0, 1, 3], session.options.list(name: "update-environment").map(&:index)
      session.options.set("update-environment", "REPLACED TWO")
      assert_equal [[0, "REPLACED"], [1, "TWO"]], session.options.list(name: "update-environment").map { |entry| [entry.index, entry.raw] }
    end
  end

  def test_hook_arrays_execute_in_index_order_at_each_declared_scope
    with_server do |server|
      session = server.list_sessions.first
      window = session.list_windows.first
      pane = window.list_panes.first
      scopes = [server.hooks(scope: :session), server.hooks(scope: :window), session.hooks, window.hooks, pane.hooks]
      scopes.each do |hooks|
        server.options(scope: :session).set("@hook-order", "")
        hooks.set("after-display-message", command: "set-option -ag @hook-order A", index: 2)
        hooks.set("after-display-message", command: "set-option -ag @hook-order B", append: true)
        assert_equal [0, 2], hooks.list(name: "after-display-message").map(&:index)
        assert_includes hooks.get("after-display-message", index: 2).raw, "@hook-order A"
        assert_raises(LibTmux::MultipleMatchesError) { hooks.get("after-display-message") }
        hooks.run("after-display-message")
        assert_equal "BA", server.options(scope: :session).get("@hook-order").raw
        hooks.unset("after-display-message", index: 2)
        hooks.run("after-display-message")
        assert_equal "BAB", server.options(scope: :session).get("@hook-order").raw
        hooks.set("after-display-message", command: "")
        empty = hooks.get("after-display-message")
        assert empty.array?
        refute empty.present?
        hooks.run("after-display-message")
        assert_equal "BAB", server.options(scope: :session).get("@hook-order").raw
        hooks.unset("after-display-message")
      end
    end
  end

  private

  def with_server
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) { |server| yield server }
    end
  end
end
