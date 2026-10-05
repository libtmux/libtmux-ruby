# frozen_string_literal: true

module LibTmuxTest
  module ControlAssertions
    def assert_run_shell_routing(control, version)
      reply = control.exchange(%q{run-shell 'printf "outside-reply\n"; exit 17'}, timeout: HANG_GUARD_SECONDS)
      refute_includes reply.blocks.map(&:body).join, "outside-reply"
      assert reply.blocks.any?(&:guard_success?)
      release = Gem::Version.new(version[/\d+\.\d+/])
      if release >= Gem::Version.new("3.3") && release < Gem::Version.new("3.5")
        # These releases put run-shell output in pane view mode.
        copy_view = "send-keys -X history-top ; send-keys -X begin-selection ; " \
          "send-keys -X history-bottom ; send-keys -X end-of-line ; " \
          "send-keys -X copy-selection-and-cancel ; show-buffer"
        output = control.exchange(copy_view, timeout: HANG_GUARD_SECONDS).blocks.map(&:body).join
        assert_includes output, "outside-reply"
        assert_includes output, "returned 17"
        control.exchange(%q{run-shell 'printf "%%end 1 1 1\n"'}, timeout: HANG_GUARD_SECONDS)
        output = control.exchange(copy_view, timeout: HANG_GUARD_SECONDS).blocks.map(&:body).join
        assert_includes output, "%end 1 1 1"
        assert_equal "alive\n", control.exchange("display-message -p alive", timeout: HANG_GUARD_SECONDS).blocks.last.body
      else
        observed = []
        loop do
          event = control.events.next(timeout: HANG_GUARD_SECONDS)
          observed << event.raw
          break if event.raw.include?("returned 17")
        end
        assert_includes observed.join, "outside-reply"
        error = assert_raises(LibTmux::ProtocolError) do
          control.exchange(%q{run-shell 'printf "%%end 1 1 1\n"'}, timeout: HANG_GUARD_SECONDS)
        end
        assert_equal :possibly_sent, error.delivery
        assert_raises(LibTmux::ClosedError) { control.exchange("display-message -p later") }
      end
    end
  end
end
