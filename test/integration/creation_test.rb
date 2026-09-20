# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"
require "socket"

class CreationTest < Minitest::Test
  def test_creation_preserves_child_directory_environment_indexes_and_exact_split_focus
    LibTmuxTest::TmuxFixture.open do |fixture|
      directory = File.dirname(fixture.socket_path)
      first_directory = File.join(directory, 'cwd #{pid};')
      second_directory = File.join(directory, "child directory")
      [first_directory, second_directory].each { |path| Dir.mkdir(path) }
      receipt = UNIXServer.new(File.join(directory, "created"))
      begin
        LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
          command = child_command(receipt.path)
          literal = "#{'#{pid}'};=\n"
          session = server.new_session(name: "workspace", command: command, window_name: 'initial #{pid};',
            cwd: first_directory, environment: {"ROOT" => "root", "LITERAL" => literal}, width: 100, height: 30)
          assert_equal [File.realpath(first_directory), "root", nil, literal], receive(receipt)
          initial = session.list_windows.first
          assert_equal "initial \#{pid};\n", initial.display('#{window_name}').text
          window = session.new_window(name: "second", command: command, index: 4, focus: true,
            cwd: second_directory, environment: {"CHILD" => "window"})
          assert_equal [File.realpath(second_directory), "root", "window", literal], receive(receipt)
          assert_equal "4\n", window.display('#{window_index}').text
          assert_equal "#{window.id}\n", session.display('#{window_id}').text
          assert_raises(LibTmux::CommandError) { session.environment("CHILD") }

          pane = window.list_panes.first
          sibling = pane.split(direction: :horizontal, size: 20, command: command,
            cwd: first_directory, environment: {"ROOT" => "override", "CHILD" => "pane"})
          assert_equal [File.realpath(first_directory), "override", "pane", literal], receive(receipt)
          assert_equal "20\n", sibling.display('#{pane_width}').text
          assert_equal "#{pane.id}\n", window.display('#{pane_id}').text
          sibling.select
          split = pane.split(direction: :vertical, size: "25%", focus: true, command: command,
            cwd: second_directory)
          assert_equal [File.realpath(second_directory), "root", nil, literal], receive(receipt)
          assert_equal pane.display('#{pane_width}').text, split.display('#{pane_width}').text
          refute_equal sibling.display('#{pane_width}').text, split.display('#{pane_width}').text
          assert_operator split.display('#{pane_height}').text.to_i, :<, sibling.display('#{pane_height}').text.to_i
          assert_equal "#{split.id}\n", window.display('#{pane_id}').text

          assert_raises(LibTmux::CommandError) { session.new_window(name: "collision", command: ["/bin/cat"], index: 4) }
          assert_equal [initial.id, window.id], session.list_windows.map(&:id)
          assert_raises(ArgumentError) { pane.split(direction: :horizontal, command: command, size: "0%") }
          assert_raises(ArgumentError) { pane.split(direction: :horizontal, command: command, environment: {"ROOT" => nil}) }
          assert_raises(ArgumentError) { session.new_window(name: "missing-dir", command: command, cwd: File.join(directory, "absent")) }
          assert_equal [initial.id, window.id], session.list_windows.map(&:id)
          assert_equal 3, window.list_panes.length
        end
      ensure
        receipt.close
      end
    end
  end

  def test_respawn_keeps_entity_identity_and_replaces_process_directory_and_environment
    LibTmuxTest::TmuxFixture.open do |fixture|
      directory = File.dirname(fixture.socket_path)
      listener = UNIXServer.new(File.join(directory, "respawn"))
      child_directory = File.join(directory, 'respawn #{pid};')
      Dir.mkdir(child_directory)
      begin
        LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
          window = server.list_windows.first
          original = window.list_panes.first
          sibling = original.split(direction: :horizontal, command: ["/bin/cat"])
          old_pid = sibling.display('#{pane_pid}').text
          assert_raises(LibTmux::CommandError) { sibling.respawn(command: ["/bin/cat"]) }
          assert_equal old_pid, sibling.display('#{pane_pid}').text
          sibling.respawn(command: child_command(listener.path), kill: true, cwd: child_directory,
            environment: {"ROOT" => "pane"}, timeout: 0.5)
          assert_equal [File.realpath(child_directory), "pane", nil, nil], receive(listener)
          refute_equal old_pid, sibling.display('#{pane_pid}').text
          assert_equal [original.id, sibling.id], window.list_panes.map(&:id)

          old_pid = original.display('#{pane_pid}').text
          window.respawn(command: child_command(listener.path), kill: true, cwd: directory,
            environment: {"ROOT" => "window"}, timeout: 0.5)
          assert_equal [File.realpath(directory), "window", nil, nil], receive(listener)
          assert_equal [original.id], window.list_panes.map(&:id)
          refute_equal old_pid, original.display('#{pane_pid}').text
          assert_raises(LibTmux::TargetNotFoundError) { sibling.display('#{pane_pid}') }
        end
      ensure
        listener.close
      end
    end
  end

  def test_global_and_hidden_environment_control_child_inheritance
    LibTmuxTest::TmuxFixture.open do |fixture|
      directory = File.dirname(fixture.socket_path)
      listener = UNIXServer.new(File.join(directory, "environment"))
      begin
        LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
          server.set_environment("ROOT", "global")
          server.set_environment("CHILD", "global secret", hidden: true)
          assert_equal "global", server.environment("ROOT")
          assert_equal "global secret", server.environment("CHILD", hidden: true)
          session = server.new_session(name: "environment", command: child_command(listener.path), cwd: directory)
          assert_equal [File.realpath(directory), "global", nil, nil], receive(listener)
          session.set_environment("ROOT", "session")
          session.set_environment("LITERAL", "session secret", hidden: true)
          assert_equal "session secret", session.environment("LITERAL", hidden: true)
          session.new_window(name: "override", command: child_command(listener.path), cwd: directory)
          assert_equal [File.realpath(directory), "session", nil, nil], receive(listener)
          session.unset_environment("ROOT")
          session.new_window(name: "fallback", command: child_command(listener.path), cwd: directory)
          assert_equal [File.realpath(directory), "global", nil, nil], receive(listener)
          server.unset_environment("CHILD")
          assert_raises(LibTmux::CommandError) { server.environment("CHILD", hidden: true) }
        end
      ensure
        listener.close
      end
    end
  end

  private

  def child_command(path)
    source = 'UNIXSocket.open(ARGV.fetch(0)) { |io| io.write(Marshal.dump([Dir.pwd, *ENV.values_at("ROOT", "CHILD", "LITERAL")])) }; STDIN.read'
    [Gem.ruby, "--disable=rubyopt,gems", "-rsocket", "-e", source, path]
  end

  def receive(listener)
    assert IO.select([listener], nil, nil, 0.5), "created pane did not report its environment"
    client = listener.accept
    begin
      assert IO.select([client], nil, nil, 0.5), "created pane receipt was empty"
      Marshal.load(client.read)
    ensure
      client.close
    end
  end
end
