# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"

class OperationBudgetTest < Minitest::Test
  # Advance the facade's clock after a real preflight, without a timer sleep.
  class AdvancingServer < LibTmux::Server
    attr_accessor :advance_after

    def run(argv, **options)
      result = super
      if argv.first == advance_after
        @clock_offset = 1.0
        self.advance_after = nil
      end
      result
    end

    private

    def monotonic
      super + (@clock_offset || 0)
    end
  end

  def test_link_and_copy_preflights_share_the_original_operation_deadline
    LibTmuxTest::TmuxFixture.open do |fixture|
      AdvancingServer.open(socket_path: fixture.socket_path) do |server|
        session = server.list_sessions.first
        window = session.new_window(name: "unselected", command: ["/bin/cat"])
        link = session.list_window_links.find { |entry| entry.id == window.id }
        server.advance_after = "show-options"
        assert_raises(LibTmux::DeadlineExceeded) { link.select(timeout: 0.5) }
        assert_equal "@0\n", session.display('#{window_id}').text
      end
      AdvancingServer.open(socket_path: fixture.socket_path) do |server|
        pane = server.list_panes.first
        server.advance_after = "list-commands"
        assert_raises(LibTmux::DeadlineExceeded) { pane.copy_mode(scroll_up: true, page_down: true, timeout: 0.5) }
        assert_equal "0\n", pane.display('#{pane_in_mode}').text
      end
      AdvancingServer.open(socket_path: fixture.socket_path) do |server|
        pane = server.list_panes.first
        usage = server.run(["list-commands", "-F", '#{command_list_usage}', "capture-pane"]).text
        supported = usage.scan(/\[-([A-Za-z]+)(?:\]|\s)/).flatten.any? { |flags| flags.include?("M") }
        server.advance_after = "list-commands"
        failure = supported ? LibTmux::DeadlineExceeded : LibTmux::UnsupportedFeatureError
        assert_raises(failure) { pane.capture(mode_screen: true, timeout: 0.5) }
      end
    end
  end

  def test_cancellation_retires_a_typed_link_preflight_blocked_in_a_hook
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.list_sessions.first
        window = session.new_window(name: "unselected", command: ["/bin/cat"])
        link = session.list_window_links.find { |entry| entry.id == window.id }
        token = LibTmux::Internal::Cancellation.new
        assert fixture.tmux("set-hook", "-g", "after-show-options[98]", "wait-for -S budget-ready ; wait-for budget-held").last.success?
        request = Thread.new do
          link.select(timeout: 0.5, cancel: token)
        rescue StandardError => error
          error
        end
        begin
          assert fixture.tmux("wait-for", "budget-ready").last.success?
          token.cancel
          assert request.join(0.5), "cancellation did not retire the blocked preflight"
          assert_instance_of LibTmux::Cancelled, request.value
          assert_equal :possibly_sent, request.value.delivery
          assert_equal "@0\n", session.display('#{window_id}').text
        ensure
          fixture.tmux("set-hook", "-gu", "after-show-options[98]")
          fixture.tmux("wait-for", "-S", "budget-held")
          token.close
          request.join(0.5)
        end
      end
    end
  end

  def test_pipe_rejects_a_command_with_no_requested_direction_before_effects
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        pane = server.list_panes.first
        assert_raises(ArgumentError) { pane.pipe(shell_command: "cat >/dev/null", input: false, output: false) }
        assert_equal "0\n", pane.display('#{pane_pipe}').text
      end
    end
  end

  def test_workspace_followup_operations_honor_precancel_before_mutation
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        window = server.list_windows.first
        original = window.list_panes.first
        sibling = original.split(direction: :horizontal, command: ["/bin/cat"])
        layout = window.display('#{window_layout}').stdout
        window.options.set("@budget", "before")
        token = LibTmux::Internal::Cancellation.new
        token.cancel
        begin
          operations = [
            -> { window.options.set("@budget", "after", timeout: 0.5, cancel: token) },
            -> { window.options.unset("@budget", timeout: 0.5, cancel: token) },
            -> { window.select_layout(:even_vertical, timeout: 0.5, cancel: token) },
            -> { sibling.select(timeout: 0.5, cancel: token) },
            -> { sibling.send_text("must not arrive", timeout: 0.5, cancel: token) },
            -> { sibling.send_keys("Enter", timeout: 0.5, cancel: token) },
            -> { sibling.kill(timeout: 0.5, cancel: token) },
            -> { sibling.respawn(command: ["/bin/cat"], kill: true, timeout: 0.5, cancel: token) },
            -> { sibling.swap(original.ref, timeout: 0.5, cancel: token) },
            -> { sibling.pipe(shell_command: "cat >/dev/null", timeout: 0.5, cancel: token) },
            -> { server.write_buffer(name: "cancelled", data: "payload", timeout: 0.5, cancel: token) }
          ]
          operations.each do |operation|
            error = assert_raises(LibTmux::Cancelled, &operation)
            assert_equal :not_sent, error.delivery
          end
          assert_equal "before", window.options.get("@budget").raw
          assert_equal layout, window.display('#{window_layout}').stdout
          assert_equal "#{original.id}\n", window.display('#{pane_id}').stdout
          assert_equal "", sibling.capture.stdout.delete("\n")
          assert_equal 2, window.list_panes.length
          assert_empty server.list_buffers
          assert_equal "0\n", sibling.display('#{pane_pipe}').text
        ensure
          token.close
        end
      end
    end
  end
end
