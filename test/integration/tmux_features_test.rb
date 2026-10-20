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

  def test_named_buffer_deletion_and_rename_need_tmux_3_4
    with_server do |server, fixture|
      server.write_buffer(name: "keep", data: "keep")
      server.write_buffer(name: "target", data: "target")
      before = server.list_buffers.map { |buffer| buffer.fetch(:name) }.sort
      if release_before?(server, 3, 4)
        [-> { server.delete_buffer("target") },
          -> { server.run(%w[delete-buffer -b target]) },
          -> { server.run(%w[deleteb -b target]) },
          -> { server.run(%w[set-option -g @x 1 ; delete-buffer -b target]) },
          -> { server.run(%w[set-buffer -b target -n renamed]) }].each do |attempt|
          error = assert_raises(LibTmux::UnsupportedFeatureError) { attempt.call }
          assert_equal [:not_sent, :admission], [error.delivery, error.phase]
          assert_match(/requires tmux 3\.4 or newer/, error.message)
        end
        assert_equal before, server.list_buffers.map { |buffer| buffer.fetch(:name) }.sort
        assert_equal "", fixture.tmux("show-option", "-gqv", "@x").first
      else
        server.delete_buffer("target")
        assert_equal ["keep"], server.list_buffers.map { |buffer| buffer.fetch(:name) }
      end
      # Named paste-and-delete has an exact lookup on every supported release.
      server.write_buffer(name: "pasted", data: "x")
      assert server.list_panes.first.paste(buffer: "pasted", delete: true).success?
      refute_includes server.list_buffers.map { |buffer| buffer.fetch(:name) }, "pasted"
    end
  end

  def test_break_out_names_the_window_and_reads_back_a_sole_pane
    with_server do |server, fixture|
      home = server.list_sessions.first
      pane = home.list_windows.first.list_panes.first.split(direction: :vertical, command: ["/bin/cat"])
      window = pane.break_out(session: home.ref, name: "broken")
      assert_equal "broken", fixture.tmux("display-message", "-p", "-t", window.id, '#{window_name}').first.strip
      assert_equal [pane.id], window.list_panes.map(&:id)

      other = server.new_session(name: "other", command: ["/bin/cat"])
      second = other.new_window(name: "solo", command: ["/bin/cat"])
      sole = second.list_panes.first
      moved = sole.break_out(session: home.ref, name: "relocated")
      assert_equal "relocated", fixture.tmux("display-message", "-p", "-t", moved.id, '#{window_name}').first.strip
      assert_includes moved.list_panes.map(&:id), sole.id
    end
  end

  # display-message fires after-display-message on every release, so identity
  # and read-back reads that used it ran a user's hook as a side effect.
  def test_identity_and_readback_reads_fire_no_display_message_hook
    with_server do |server, fixture|
      assert fixture.tmux("set-hook", "-g", "after-display-message", "set-option -g @hook-display fired ; wait-for -S hook-display").last.success?
      snapshot = server.snapshot
      assert_equal server.__send__(:tmux_release).text, snapshot.server_info.fetch(:version)
      home = server.list_sessions.first
      other = server.new_session(name: "other", command: ["/bin/cat"])
      other.list_windows.first.list_panes.first.break_out(session: home.ref, name: "moved")
      assert_equal "", fixture.tmux("show-option", "-gqv", "@hook-display").first

      fixture.tmux("display-message", "-p", "control")
      assert fixture.tmux("wait-for", "hook-display").last.success?
      assert_equal "fired", fixture.tmux("show-option", "-gqv", "@hook-display").first.strip
    end
  end

  def test_exact_tmux_3_7_refuses_raw_break_pane_without_effect
    with_server do |server, _fixture|
      pane = server.list_panes.first.split(direction: :vertical, command: ["/bin/cat"])
      windows = server.list_windows.map(&:id)
      if exact_release?(server, 3, 7)
        error = assert_raises(LibTmux::UnsupportedFeatureError) { server.run(["break-pane", "-d", "-s", pane.id]) }
        assert_equal [:not_sent, :admission], [error.delivery, error.phase]
        assert_equal windows, server.list_windows.map(&:id)
      else
        assert server.run(["break-pane", "-d", "-s", pane.id]).success?
        assert_equal windows.length + 1, server.list_windows.length
      end
    end
  end

  def test_exact_tmux_3_7_refuses_break_pane_over_a_control_connection_and_the_daemon_survives
    with_server do |server, fixture|
      session = server.list_sessions.first
      server.list_panes.first.split(direction: :vertical, command: ["/bin/cat"])
      next unless server.supports_control?

      windows = server.list_windows.map(&:id)
      server.open_control(session: session.ref) do |control|
        lines = ["break-pane", "breakp -d", "break-p", "display-message -p ok ; break-pane"]
        if exact_release?(server, 3, 7)
          lines.each do |line|
            error = assert_raises(LibTmux::UnsupportedFeatureError, line) { control.exchange(line, timeout: 1) }
            assert_equal [:not_sent, :admission], [error.delivery, error.phase]
          end
          assert_equal windows, server.list_windows.map(&:id)
          assert_equal "alive\n", control.exchange("display-message -p alive", timeout: 1).blocks.last.body
        else
          control.exchange("break-pane -d", timeout: 1)
          assert_equal windows.length + 1, server.list_windows.length
        end
      end
      assert fixture.tmux("has-session", "-t", "fixture").last.success?
    end
  end

  def test_exact_tmux_3_7_refuses_break_pane_over_an_async_control_connection
    with_server do |server, fixture|
      session = server.list_sessions.first
      server.list_panes.first.split(direction: :vertical, command: ["/bin/cat"])
      next unless server.supports_control? && exact_release?(server, 3, 7)

      Async do |parent|
        LibTmux::Async.open(parent: parent, server: server) do |scope|
          scope.server.open_control(session: session.ref) do |control|
            error = assert_raises(LibTmux::UnsupportedFeatureError) { control.exchange("break-pane", timeout: 1) }
            assert_equal [:not_sent, :admission], [error.delivery, error.phase]
            assert_equal "alive\n", control.exchange("display-message -p alive", timeout: 1).blocks.last.body
          end
        end
      end.wait
      assert fixture.tmux("has-session", "-t", "fixture").last.success?
    end
  end

  def test_exact_tmux_3_7_refuses_raw_names_with_colon_or_period_like_the_typed_calls
    with_server do |server, _fixture|
      session = server.list_sessions.first
      sessions = server.list_sessions.map(&:id)
      windows = server.list_windows.map(&:id)
      raw = [%w[new-session -d -s a.b], %w[new -d -s c:d], %w[new-window -d -n a.b], %w[neww -d -n c:d],
        ["rename-window", "-t", session.id, "a.b"], ["renamew", "-t", session.id, "a.b"],
        ["rename-session", "-t", session.id, "a.b"], ["rename", "-t", session.id, "c:d"]]
      if exact_release?(server, 3, 7)
        raw.each do |argv|
          error = assert_raises(LibTmux::UnsupportedFeatureError, argv.join(" ")) { server.run(argv) }
          assert_equal [:not_sent, :admission], [error.delivery, error.phase]
        end
        assert_equal sessions, server.list_sessions.map(&:id)
        assert_equal windows, server.list_windows.map(&:id)
      else
        assert server.run(%w[new-window -d -n a.b]).success?
      end
    end
  end

  def test_exact_tmux_3_7_refuses_colon_and_period_in_names_before_dispatch
    with_server do |server, _fixture|
      sessions = server.list_sessions.map(&:id)
      if exact_release?(server, 3, 7)
        ["dotted.name", "colon:name"].each do |name|
          error = assert_raises(LibTmux::UnsupportedFeatureError) { server.new_session(name: name, command: ["/bin/cat"]) }
          assert_equal [:not_sent, :admission], [error.delivery, error.phase]
          assert_raises(LibTmux::UnsupportedFeatureError) { server.list_sessions.first.rename(name) }
        end
        assert_equal sessions, server.list_sessions.map(&:id)
      else
        assert_kind_of LibTmux::Session, server.new_session(name: "dotted.name", command: ["/bin/cat"])
      end
      assert_kind_of LibTmux::Session, server.new_session(name: "plain-name", command: ["/bin/cat"])
    end
  end

  def test_percentage_splits_use_the_portable_size_flag_and_raw_p_is_refused_on_3_4
    with_server do |server, _fixture|
      pane = server.list_panes.first
      assert_kind_of LibTmux::Pane, pane.split(direction: :horizontal, size: "40%", command: ["/bin/cat"])
      panes = server.list_panes.length
      if exact_release?(server, 3, 4)
        error = assert_raises(LibTmux::UnsupportedFeatureError) { server.run(["split-window", "-d", "-p", "30", "-t", pane.id]) }
        assert_equal :not_sent, error.delivery
        assert_equal panes, server.list_panes.length
      else
        assert server.run(["split-window", "-d", "-p", "30", "-t", pane.id, "/bin/cat"]).success?
        assert_equal panes + 1, server.list_panes.length
      end
    end
  end

  def test_malformed_layouts_are_refused_before_tmux_3_4_and_the_daemon_survives
    with_server do |server, fixture|
      window = server.list_windows.first
      if release_before?(server, 3, 4)
        ["garbage", "zzzz,0x0"].each do |layout|
          error = assert_raises(LibTmux::UnsupportedFeatureError) { server.run(["select-layout", "-t", window.id, layout]) }
          assert_equal :not_sent, error.delivery
          assert_raises(ArgumentError) { window.select_layout(layout) }
        end
      else
        refute server.run(["select-layout", "-t", window.id, "garbage"]).success?
      end
      assert window.select_layout("tiled").success?
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
    server.__send__(:tmux_release).exactly?(major, minor)
  end
end
