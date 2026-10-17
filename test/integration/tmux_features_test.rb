# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/async"
require_relative "../support/tmux_fixture"
require_relative "../support/control_support"

# Each optional feature is refused on the daemons that mishandle it and works
# on the others, with the refused call leaving no effect behind.
class TmuxFeaturesTest < Minitest::Test
  include LibTmuxTest::ControlSupport

  def test_control_clients_attach_only_to_tmux_3_7_and_newer
    with_server do |server, fixture|
      session = server.list_sessions.first
      if control_supported?(server)
        server.open_control(session: session.ref) do |control|
          assert_equal "ready\n", control.exchange("display-message -p ready", timeout: 0.5).blocks.last.body
        end
      else
        refute require_control_support(server, session)
        Async do |parent|
          LibTmux::Async.open(parent: parent, server: server) do |scope|
            error = assert_raises(LibTmux::UnsupportedFeatureError) { scope.server.open_control(session: session.ref) }
            assert_equal :not_sent, error.delivery
          end
        end.wait
        pin = LibTmux::Internal::SocketIdentity.new(server.endpoint)
        begin
          refute require_control_binding(pin)
        ensure
          pin.close
        end
        assert_empty server.list_clients
      end
      assert fixture.tmux("has-session", "-t", "fixture").last.success?
    end
  end

  private

  def with_server
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path, executable: fixture.executable) do |server|
        yield server, fixture
      end
    end
  end

  def release_before?(server, major, minor)
    (server.__send__(:tmux_release).key.first(2) <=> [major, minor]).negative?
  end

  def exact_release?(server, major, minor)
    server.__send__(:tmux_release).key == [major, minor, 0, 1]
  end
end
