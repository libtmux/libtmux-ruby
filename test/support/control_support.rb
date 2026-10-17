# frozen_string_literal: true

module LibTmuxTest
  # Control clients attach only to tmux 3.7 and newer. Where an older daemon
  # cannot run the behavior under test, the test asserts the refusal instead.
  module ControlSupport
    def control_supported?(server)
      release = server.__send__(:tmux_release)
      (release <=> LibTmux::Internal::TmuxVersion.parse("3.7")) >= 0
    end

    # Returns true when the daemon accepts control clients. Otherwise it asserts
    # that acquisition is refused before a client attaches, and returns false.
    def require_control_support(server, session = nil)
      return true if control_supported?(server)

      session ||= server.list_sessions.first
      error = assert_raises(LibTmux::UnsupportedFeatureError) { server.open_control(session: session.ref) }
      assert_equal [:not_sent, :admission], [error.delivery, error.phase]
      assert_match(/control connections require tmux 3\.7 or newer/, error.message)
      assert_empty server.list_clients
      false
    end

    # The same check for a binding that no server checked, which probes the
    # daemon itself.
    def require_control_binding(pin)
      release = LibTmux::Internal::TmuxVersion.connected(pin.command_prefix) do |argv|
        LibTmux::Internal::ProcessExecutor.new.run(argv, timeout: 5.0)
      end
      return true if (release <=> LibTmux::Internal::TmuxVersion.parse("3.7")) >= 0

      error = assert_raises(LibTmux::UnsupportedFeatureError) do
        LibTmux::ControlConnection.new(binding: pin, session_id: "$0")
      end
      assert_equal [:not_sent, :admission], [error.delivery, error.phase]
      false
    end
  end
end
