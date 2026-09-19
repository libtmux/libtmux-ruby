# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"

class SessionGuardTest < Minitest::Test
  def test_conditional_kill_refuses_unknown_windows_and_allows_proven_membership
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        owned = server.new_session(name: "owned", command: ["cat"])
        expected = owned.list_windows.map(&:ref)
        panes = owned.list_panes.map(&:ref)
        borrowed = server.list_sessions.find { |session| session.id != owned.id }
        borrowed_window = borrowed.list_windows.first
        assert_raises(LibTmux::TargetNotFoundError) { owned.kill(expected_windows: [], expected_panes: []) }
        owned.link_window(borrowed_window.ref, index: 9)
        assert_raises(LibTmux::TargetNotFoundError) { owned.kill(expected_windows: expected, expected_panes: panes) }
        assert_includes server.list_windows.map(&:ref), borrowed_window.ref
        owned.list_window_links.find { |link| link.id == borrowed_window.id }.unlink
        assert owned.kill(expected_windows: expected, expected_panes: panes).success?
        assert_equal [borrowed.ref], server.list_sessions.map(&:ref)
        assert_includes server.list_windows.map(&:ref), borrowed_window.ref
      end
    end
  end

  def test_guard_rechecks_panes_after_preflight_wait_and_bypasses_static_aliases
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        borrowed = server.list_panes.first
        created = server.new_session(name: "guarded", command: ["cat"], receipt: true)
        server.options(scope: :server).set("command-alias", "if-shell=wait-for never", index: 90)
        server.options(scope: :server).set("command-alias", "kill-session=wait-for never", index: 91)
        assert fixture.tmux("set-hook", "-g", "after-show-options[99]", "wait-for -S ownership-ready ; wait-for ownership-release").last.success?
        request = Thread.new do
          created.entity.kill(expected_windows: [created.window.ref], expected_panes: [created.pane.ref])
        rescue LibTmux::TargetNotFoundError => error
          error
        end
        begin
          assert fixture.tmux("wait-for", "ownership-ready").last.success?
          assert fixture.tmux("join-pane", "-d", "-s", borrowed.id, "-t", created.pane.id).last.success?
          assert fixture.tmux("set-hook", "-gu", "after-show-options[99]").last.success?
          assert fixture.tmux("wait-for", "-S", "ownership-release").last.success?
          assert request.join(0.5), "ownership guard did not settle"
          assert_instance_of LibTmux::TargetNotFoundError, request.value
          assert_includes server.list_panes.map(&:ref), borrowed.ref
          assert_includes server.list_sessions.map(&:ref), created.entity.ref
        ensure
          fixture.tmux("set-hook", "-gu", "after-show-options[99]")
          fixture.tmux("wait-for", "-S", "ownership-release")
          request.join(0.5)
        end
      end
    end
  end
end
