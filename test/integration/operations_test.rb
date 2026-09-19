# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"

class OperationsTest < Minitest::Test
  def test_options_hooks_and_environment_preserve_scope_sparse_indexes_and_bytes
    with_server do |server, _fixture|
      session = server.list_sessions.fetch(0)
      pane = session.list_panes.fetch(0)
      value = "first\n\#{pane_id};\\\n\\377\xff\\001\x01\t'\"$`".b
      server.options(scope: :session).set("@literal", value)
      inherited = session.options.get("@literal")
      assert_equal value.b, inherited.raw
      assert inherited.inherited?
      session.options.set("@literal", "local;")
      assert_equal "local;".b, session.options.get("@literal").raw
      session.options.unset("@literal")
      assert_equal value.b, session.options.get("@literal").raw
      session.options.set("@\#{pid}", "~literal;")
      assert_equal "~literal;".b, session.options.get("@\#{pid}").raw
      session.options.unset("@\#{pid}")
      pane.options.set("@flag", true)
      assert_equal true, pane.options.get("@flag").as(:boolean)
      assert_raises(LibTmux::FieldDecodeError) { pane.options.get("@flag").as(:integer) }
      assert_raises(LibTmux::FieldDecodeError) { inherited.as(:string) }
      window = session.list_windows.fetch(0)
      window.options.set("pane-border-format", "a")
      window.options.set("pane-border-format", "b", append: true)
      assert_equal "ab".b, window.options.get("pane-border-format").raw
      session.options.set("update-environment", "ONE", index: 2)
      session.options.set("update-environment", "TWO", index: 7)
      rows = session.options.list(name: "update-environment")
      assert_equal [2, 7], rows.map(&:index)
      assert_equal ["ONE", "TWO"], rows.map(&:raw)
      session.options.unset("update-environment", index: 2)
      assert_equal [7], session.options.list(name: "update-environment").map(&:index)
      assert_equal "TWO", session.options.get("update-environment", index: 7).raw
      session.hooks.set("after-new-window", command: "set-option -t #{session.id} @hook ran", index: 4)
      assert_equal [4], session.hooks.list(name: "after-new-window").map(&:index)
      session.hooks.run("after-new-window")
      assert_equal "ran".b, session.options.get("@hook").raw
      session.hooks.unset("after-new-window", index: 4)
      session.set_environment("LIBTMUX_TEST", value)
      assert_equal value.b, session.environment("LIBTMUX_TEST")
      session.unset_environment("LIBTMUX_TEST")
      assert_raises(LibTmux::CommandError) { session.environment("LIBTMUX_TEST") }
    end
  end

  def test_buffer_bytes_capture_flags_and_copy_commands
    with_server do |server, _fixture|
      pane = server.list_panes.fetch(0)
      payload = "NUL\0\xff\n\n".b
      server.write_buffer(name: "literal ;", data: payload)
      assert_equal payload, server.read_buffer("literal ;").stdout
      assert_equal [["literal ;", payload.bytesize]], server.list_buffers.map { |row| [row.fetch(:name), row.fetch(:size)] }
      server.write_buffer(name: "paste", data: "one\ntwo\n")
      assert pane.paste(buffer: "paste", delete: true, separator: " ").success?
      assert_raises(LibTmux::CommandError) { server.read_buffer("paste") }
      assert pane.capture(start: 0, finish: 0, join: true, escapes: true).stdout.end_with?("\n")
      assert pane.copy_mode(scroll_up: true, source: pane.ref).success?
      assert_equal "1\n", pane.display('#{pane_in_mode}').text
      assert pane.copy_command("cancel").success?
      assert_equal "0\n", pane.display('#{pane_in_mode}').text
      server.delete_buffer("literal ;")
      assert_empty server.list_buffers
    end
  end

  def test_manipulations_keep_entity_ids_and_link_context_explicit
    with_server do |server, _fixture|
      session = server.list_sessions.fetch(0)
      session.rename("renamed \#{pid};")
      assert_equal "renamed \#{pid};\n", session.display('#{session_name}').text
      window = session.new_window(name: "source", command: ["/bin/cat"])
      window.rename("window \#{pid};")
      assert_equal "window \#{pid};\n", window.display('#{window_name}').text
      pane = window.list_panes.fetch(0)
      split = window.split(direction: :horizontal, command: ["/bin/cat"])
      split.resize(width: 20)
      assert_equal "20\n", split.display('#{pane_width}').text
      positions = [split, pane].map { |entry| entry.display('#{pane_left}:#{pane_top}').stdout }
      split.swap(pane.ref)
      assert_equal positions.reverse, [split, pane].map { |entry| entry.display('#{pane_left}:#{pane_top}').stdout }
      split.select
      assert_equal "1\n", split.display('#{pane_active}').text
      destination = split.break_out(session: session.ref, name: "broken;")
      assert_includes destination.list_panes.map(&:id), split.id
      split.join(pane.ref, direction: :vertical)
      assert_equal [pane.id, split.id].sort, window.list_panes.map(&:id).sort
      split.move(pane.ref, direction: :horizontal, before: true)
      assert_operator split.display('#{pane_left}').text.to_i, :<, pane.display('#{pane_left}').text.to_i
      split.respawn(command: ["/bin/cat"], kill: true)
      session.link_window(window.ref, index: 8)
      session.link_window(window.ref, index: 9)
      links = session.list_window_links.select { |link| link.window.id == window.id }
      assert_equal [1, 8, 9], links.map(&:index)
      assert_equal 3, links.map(&:ref).uniq.length
      assert links.all? { |link| link.session.ref == session.ref }
      assert links.all?(&:frozen?)
      assert links.last.select.success?
      assert_equal "9\n", session.display('#{window_index}').text
      assert links.last.unlink.success?
      assert_raises(LibTmux::TargetNotFoundError) { links.last.select }
      links.first.swap(links.fetch(1).ref)
      links.fetch(1).move(session: session.ref, index: 7)
      assert_raises(LibTmux::TargetNotFoundError) { links.fetch(1).unlink }
      moved = session.list_window_links.find { |link| link.index == 7 }
      assert_equal window.ref, moved.window.ref
      assert_equal "literal ' ; \#{window_id}\n", moved.display("literal ' ; #\#{window_id}").text
    end
  end

  def test_link_guard_rechecks_after_hook_wait_and_ignores_configured_command_aliases
    with_server do |server, fixture|
      session = server.list_sessions.first
      original = session.list_windows.first
      replacement = session.new_window(name: "replacement", command: ["/bin/cat"])
      session.link_window(original.ref, index: 8)
      link = session.list_window_links.find { |entry| entry.index == 8 }
      server.options(scope: :server).set("command-alias", "if-shell=wait-for never", index: 90)
      server.options(scope: :server).set("command-alias", "select-window=wait-for never", index: 91)
      assert link.select.success?
      assert fixture.tmux("set-hook", "-g", "after-show-options[99]", "wait-for -S link-ready ; wait-for link-release").last.success?
      request = Thread.new do
        link.unlink
      rescue LibTmux::TargetNotFoundError => error
        error
      end
      begin
        assert fixture.tmux("wait-for", "link-ready").last.success?
        assert fixture.tmux("link-window", "-k", "-s", replacement.id, "-t", "#{session.id}:8").last.success?
        assert fixture.tmux("set-hook", "-gu", "after-show-options[99]").last.success?
        assert fixture.tmux("wait-for", "-S", "link-release").last.success?
        assert request.join(0.5), "link guard did not finish"
        assert_instance_of LibTmux::TargetNotFoundError, request.value
        assert_equal replacement.id, session.list_window_links.find { |entry| entry.index == 8 }.id
      ensure
        fixture.tmux("set-hook", "-gu", "after-show-options[99]")
        fixture.tmux("wait-for", "-S", "link-release")
        request.join(0.5)
      end
    end
  end

  def test_missing_alias_inventory_cannot_turn_a_guarded_mutation_into_false_success
    with_server do |server, _fixture|
      session = server.list_sessions.first
      window = session.list_windows.first
      session.link_window(window.ref, index: 8)
      link = session.list_window_links.find { |entry| entry.index == 8 }
      server.options.set("command-alias", "if-shell=", index: 90)
      server.options.set("command-alias", "show-options=", index: 91)
      outcome = begin
        link.unlink(timeout: 0.5)
      rescue LibTmux::UnsupportedFeatureError, LibTmux::CommandError => error
        error
      end
      assert_equal [0, 8], session.list_window_links.map(&:index)
      if outcome.is_a?(LibTmux::CommandError)
        # Older tmux rejects the empty alias while acquiring the inventory.
        assert_equal :observed, outcome.delivery
        assert_includes outcome.result.argv, "show-options"
      else
        assert_instance_of LibTmux::UnsupportedFeatureError, outcome
        assert_equal :not_sent, outcome.delivery
      end
    end
  end

  def test_swapping_distinct_window_links_preserves_windows_and_invalidates_old_occurrences
    with_server do |server, _fixture|
      session = server.list_sessions.first
      initial = session.list_windows.first
      other = session.new_window(name: "other", command: ["/bin/cat"])
      first, second = session.list_window_links
      assert first.swap(second.ref, timeout: 0.5).success?
      assert_equal [[0, other.id], [1, initial.id]], session.list_window_links.map { |link| [link.index, link.id] }
      assert_raises(LibTmux::TargetNotFoundError) { first.select }
      assert_raises(LibTmux::TargetNotFoundError) { second.select }
      assert_equal "#{initial.id}\n", initial.display('#{window_id}').stdout
      assert_equal "#{other.id}\n", other.display('#{window_id}').stdout

      left, right = initial.list_panes.first, other.list_panes.first
      assert left.swap(right.ref, timeout: 0.5).success?
      assert_equal [right.id], initial.list_panes.map(&:id)
      assert_equal [left.id], other.list_panes.map(&:id)
    end
  end

  def test_resize_zoom_and_layout_restore_geometry_without_changing_focus
    with_server do |server, _fixture|
      window = server.list_windows.first
      window.resize(width: 80, height: 30)
      first = window.list_panes.first
      second = first.split(direction: :vertical, command: ["/bin/cat"])
      second.select
      first.resize(height: 7)
      assert_equal "7\n", first.display('#{pane_height}').text
      previous = second.display('#{pane_height}').text.to_i
      first.resize(direction: :down, amount: 2)
      assert_equal "9\n", first.display('#{pane_height}').text
      assert_equal previous - 2, second.display('#{pane_height}').text.to_i
      layout = window.display('#{window_layout}').text.strip

      first.resize(zoom: true)
      assert_equal "1\n", window.display('#{window_zoomed_flag}').text
      assert_equal "80:30\n", first.display('#{pane_width}:#{pane_height}').text
      first.resize(zoom: true)
      assert_equal "0\n", window.display('#{window_zoomed_flag}').text
      assert_equal layout, window.display('#{window_layout}').text.strip

      second.select
      window.select_layout(:even_horizontal)
      assert_equal [30, 30], window.list_panes.map { |pane| pane.display('#{pane_height}').text.to_i }
      assert_equal "#{second.id}\n", window.display('#{pane_id}').text
      window.select_layout(layout)
      assert_equal layout, window.display('#{window_layout}').text.strip
      assert_equal "#{second.id}\n", window.display('#{pane_id}').text
      assert_raises(LibTmux::CommandError) { window.select_layout("not-a-layout") }
      assert_equal layout, window.display('#{window_layout}').text.strip
    end
  end

  def test_link_moves_and_last_link_destruction_keep_other_windows_owned
    with_server do |server, _fixture|
      left = server.list_sessions.first
      right = server.new_session(name: "destination", command: ["/bin/cat"])
      preserved = [left.list_windows.first.id, right.list_windows.first.id]
      moving = left.new_window(name: "moving", command: ["/bin/cat"])
      original = left.list_window_links.find { |link| link.id == moving.id }
      assert_raises(LibTmux::CommandError) { original.move(session: right.ref, index: 0) }
      assert_includes left.list_windows.map(&:id), moving.id
      original.move(session: right.ref, index: 7)
      assert_raises(LibTmux::TargetNotFoundError) { original.kill }
      refute_includes left.list_windows.map(&:id), moving.id
      moved = right.list_window_links.find { |link| link.index == 7 }
      assert_equal moving.ref, moved.window.ref
      left.link_window(moving.ref, index: 9)
      moved.kill
      assert_equal preserved.sort, server.list_windows.map(&:id).sort
      assert_raises(LibTmux::TargetNotFoundError) { moved.select }

      sole = left.new_window(name: "sole", command: ["/bin/cat"])
      only = left.list_window_links.find { |link| link.id == sole.id }
      assert_raises(LibTmux::CommandError) { only.unlink }
      assert_includes left.list_windows.map(&:id), sole.id
      only.unlink(force: true)
      assert_equal preserved.sort, server.list_windows.map(&:id).sort
      assert_equal [left.id, right.id], server.list_sessions.map(&:id)
    end
  end

  def test_source_file_and_wait_channels_preserve_literal_arguments_and_final_outcomes
    with_server do |server, fixture|
      config = File.join(File.dirname(fixture.socket_path), 'config #{pid};.conf')
      File.write(config, "set-option -g @source-loaded 'literal ; value'\n")
      assert server.source_file(config, timeout: 0.5).success?
      assert_equal "literal ; value", server.options(scope: :session).get("@source-loaded").raw
      File.write(config, "set-option -g @source-loaded changed\nset-option -g nonexistent-option invalid\n")
      failure = assert_raises(LibTmux::CommandError) { server.source_file(config, timeout: 0.5) }
      assert_equal :observed, failure.delivery
      assert_equal "changed", server.options(scope: :session).get("@source-loaded").raw

      channel = 'channel #{pid};'
      assert server.wait_for(channel, action: :signal, timeout: 0.5).success?
      assert server.wait_for(channel, timeout: 0.5).success?
      assert server.wait_for(channel, action: :lock, timeout: 0.5).success?
      blocked = assert_raises(LibTmux::DeadlineExceeded) { server.wait_for(channel, action: :lock, timeout: 0.1) }
      assert_equal :possibly_sent, blocked.delivery
      assert server.wait_for(channel, action: :unlock, timeout: 0.5).success?
      # The retired client's queued lock still acquires in tmux after unlock.
      assert server.wait_for(channel, action: :unlock, timeout: 0.5).success?
      assert server.wait_for(channel, action: :lock, timeout: 0.5).success?
      assert server.wait_for(channel, action: :unlock, timeout: 0.5).success?
    end
  end

  private

  def with_server
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) { |server| yield server, fixture }
    end
  end
end
