# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"
require "libtmux/async"
require "pty"

class EndpointDefaultsTest < Minitest::Test
  def test_default_server_captures_endpoint_environment_and_executable_for_all_clients
    original = ENV.to_h
    LibTmuxTest::TmuxFixture.open do |fixture|
      directory = File.dirname(fixture.socket_path)
      log = File.join(directory, "clients.jsonl")
      executable = File.join(directory, "tmux")
      real_tmux = LibTmux::Endpoint.new(socket_path: fixture.socket_path, executable: fixture.executable).executable
      File.write(executable, <<~SH)
        #!/bin/sh
        printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$LIBTMUX_RUBY_KEEP" "${LIBTMUX_RUBY_ADDED+x}" "${TMUX+x}" "${TMUX_PANE+x}" "$PATH" "$*" >> #{log}
        exec #{real_tmux} "$@"
      SH
      File.chmod(0o700, executable)
      ENV["PATH"] = directory
      ENV["LIBTMUX_SOCKET_PATH"] = fixture.socket_path
      ENV["LIBTMUX_SOCKET_NAME"] = "../ignored"
      ENV["TMUX"] = "invalid-but-lower-precedence"
      ENV["TMUX_PANE"] = "%99"
      ENV["LIBTMUX_RUBY_KEEP"] = "captured"
      ENV.delete("LIBTMUX_RUBY_ADDED")
      LibTmux::Server.open do |server|
        assert_equal fixture.socket_path, server.endpoint.socket_path
        assert_equal executable, server.endpoint.executable
        ENV["PATH"] = "/does-not-exist"
        ENV["LIBTMUX_SOCKET_PATH"] = "/must-not-connect"
        ENV["LIBTMUX_RUBY_KEEP"] = "changed"
        ENV["LIBTMUX_RUBY_ADDED"] = "after-construction"
        host = ENV.to_h
        probe = server.run(["display-message", "-p", "captured"])
        assert probe.success?, probe.stderr
        session = server.list_sessions.fetch(0)
        server.open_control(session: session.ref) do |control|
          assert_equal "core\n", control.exchange('display-message -p core').blocks.last.body
        end
        Async do |task|
          LibTmux::Async.open(parent: task, server: server) do |scope|
            assert_equal [session.id], scope.server.list_sessions.map(&:id)
            scope.server.open_control(session: session.ref) do |control|
              assert_equal "async\n", control.exchange('display-message -p async').blocks.last.body
            end
          end
        end.wait
        server.run(["set-hook", "-g", "client-attached", "wait-for -S defaults-terminal"])
        PTY.open do |_master, slave|
          slave.winsize = [24, 80]
          worker = Thread.new { server.attach(session: session.ref, terminal: slave, term: "xterm", timeout: 0.5) }
          begin
            assert server.run(["wait-for", "defaults-terminal"]).success?
            assert server.run(["detach-client", "-s", session.id]).success?
            assert worker.join(0.5), "terminal client did not retire"
            assert worker.value.success?
          ensure
            worker.join(0.5)
          end
        end
        LibTmux::Server.start(env: server.endpoint.environment) do |owned|
          assert_equal "captured", owned.environment("LIBTMUX_RUBY_KEEP")
        end
        assert_equal host, ENV.to_h
      end
      clients = File.readlines(log).map do |line|
        keep, added, tmux, pane, path, arguments = line.chomp.split("\t", -1)
        {"keep" => keep, "added" => added == "x", "tmux" => tmux == "x", "pane" => pane == "x", "path" => path, "control" => arguments.split.include?("-C"), "daemon" => arguments.split.include?("-D")}
      end
      assert_operator clients.length, :>=, 6
      assert_equal 2, clients.count { |client| client.fetch("control") }
      assert_equal 1, clients.count { |client| client.fetch("daemon") }
      clients.each do |client|
        assert_equal "captured", client.fetch("keep")
        assert_equal directory, client.fetch("path")
        refute client.fetch("added")
        refute client.fetch("tmux")
        refute client.fetch("pane")
      end
    end
  ensure
    ENV.replace(original)
  end

  def test_session_scope_cleans_the_captured_id_after_rename_and_name_reuse
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        owned_id = nil
        value = server.with_session(name: "scope", command: ["/bin/cat"]) do |session|
          owned_id = session.id
          assert server.run(["rename-session", "-t", session.id, "renamed"]).success?
          server.new_session(name: "scope", command: ["/bin/cat"])
          :result
        end
        assert_equal :result, value
        refute_includes server.list_sessions.map(&:id), owned_id
        assert_equal ["fixture", "scope"], fixture.tmux("list-sessions", "-F", '#{session_name}').first.lines.map(&:chomp).sort
      end
    end
  end

  def test_explicit_owned_named_endpoint_starts_in_a_fresh_root_and_retires_daemon
    Dir.mktmpdir("libtmux-ruby-named-") do |root|
      endpoint = LibTmux::Endpoint.new(env: {"LIBTMUX_SOCKET_NAME" => "selected", "TMUX_TMPDIR" => root})
      pid = private_path = nil
      LibTmux::Server.start(endpoint: endpoint) do |server|
        assert_equal endpoint, server.endpoint
        assert File.socket?(endpoint.socket_path)
        assert_equal 0o700, File.stat(File.dirname(endpoint.socket_path)).mode & 0o777
        pid = Integer(server.run(["display-message", "-p", '#{pid}']).text)
        private_path = server.run(["display-message", "-p", '#{socket_path}']).text.strip
        assert private_path.start_with?(File.dirname(endpoint.socket_path) + "/")
        retained = File.join(File.dirname(private_path), "identity")
        assert_equal File.lstat(endpoint.socket_path).ino, File.lstat(retained).ino
        LibTmux::Server.open(env: {"LIBTMUX_SOCKET_NAME" => "selected", "TMUX_TMPDIR" => root}) do |borrowed|
          assert_equal "#{pid}\n", borrowed.run(["display-message", "-p", '#{pid}']).text
        end
      end
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      refute File.exist?(endpoint.socket_path)
      refute File.exist?(File.dirname(private_path))
    end
  end

  def test_named_directory_permissions_collisions_and_filesystem_components
    Dir.mktmpdir("libtmux-ruby-root-") do |root|
      directory = File.join(root, "tmux-#{Process.uid}")
      endpoint = LibTmux::Endpoint.new(socket_name: "selected", socket_directory: root)
      Dir.mkdir(directory, 0o750)
      LibTmux::Server.start(endpoint: endpoint) do |server|
        pid = server.run(["display-message", "-p", '#{pid}']).text
        assert_raises(Errno::EEXIST) { LibTmux::Server.start(endpoint: endpoint) }
        assert_equal pid, server.run(["display-message", "-p", '#{pid}']).text
        assert_equal 1, Dir.children(directory).count { |name| name.start_with?(".libtmux-") }
      end
      File.chmod(0o705, directory)
      assert_raises(ArgumentError) { LibTmux::Server.start(endpoint: endpoint) }
      File.chmod(0o700, directory)
      Dir.rmdir(directory)
      Dir.mkdir(File.join(root, "real"), 0o700)
      File.symlink(File.join(root, "real"), directory)
      assert_raises(ArgumentError) { LibTmux::Server.start(endpoint: endpoint) }
      File.unlink(directory)
      File.write(directory, "not a directory")
      assert_raises(ArgumentError) { LibTmux::Server.start(endpoint: endpoint) }
      File.unlink(directory)
      missing = LibTmux::Endpoint.new(socket_name: "selected", socket_directory: File.join(root, "missing", ".."))
      assert_raises(Errno::ENOENT) { LibTmux::Server.start(endpoint: missing) }
      refute File.exist?(directory)
      if Process.uid.zero?
        Dir.mkdir(directory, 0o700)
        File.chown(1, -1, directory)
        assert_raises(ArgumentError) { LibTmux::Server.start(endpoint: endpoint) }
        File.chown(Process.uid, -1, directory)
      end
    end
  end

  def test_published_endpoint_collision_cannot_remove_an_existing_file_or_replacement_daemon
    Dir.mktmpdir("libtmux-ruby-publish-") do |root|
      endpoint = LibTmux::Endpoint.new(socket_path: File.join(root, "socket"))
      File.write(endpoint.socket_path, "keep existing file")
      assert_raises(Errno::EEXIST) { LibTmux::Server.start(endpoint: endpoint) }
      assert_equal "keep existing file", File.read(endpoint.socket_path)
      assert_equal ["socket"], Dir.children(root)
      File.unlink(endpoint.socket_path)
      first = LibTmux::Server.start(endpoint: endpoint)
      first_pid = Integer(first.run(["display-message", "-p", '#{pid}']).text)
      File.unlink(endpoint.socket_path)
      second = LibTmux::Server.start(endpoint: endpoint)
      second_pid = Integer(second.run(["display-message", "-p", '#{pid}']).text)
      first.close
      assert_raises(Errno::ESRCH) { Process.kill(0, first_pid) }
      assert File.socket?(endpoint.socket_path)
      assert_equal "#{second_pid}\n", second.run(["display-message", "-p", '#{pid}']).text
    ensure
      first&.close
      second&.close
    end
  end

  def test_removed_root_and_explicit_missing_parent_do_not_start_elsewhere
    Dir.mktmpdir("libtmux-ruby-removed-") do |root|
      selected = File.join(root, "selected")
      Dir.mkdir(selected)
      endpoint = LibTmux::Endpoint.new(socket_name: "unique", socket_directory: selected)
      Dir.rmdir(selected)
      original = Process.method(:spawn)
      Process.define_singleton_method(:spawn) { |*_, **| flunk "missing root attempted a process launch" }
      begin
        assert_raises(Errno::ENOENT) { LibTmux::Server.start(endpoint: endpoint) }
      ensure
        Process.define_singleton_method(:spawn, original)
      end
      refute Dir.exist?(selected)
      endpoint = LibTmux::Endpoint.new(socket_path: File.join(selected, "socket"))
      assert_raises(Errno::ENOENT) { LibTmux::Server.start(endpoint: endpoint) }
      refute Dir.exist?(selected)
    end
  end

  def test_symlink_parent_traversal_keeps_the_filesystem_selected_root
    Dir.mktmpdir("libtmux-ruby-parent-") do |root|
      Dir.mkdir(File.join(root, "actual"))
      Dir.mkdir(File.join(root, "actual", "child"))
      File.symlink(File.join(root, "actual", "child"), File.join(root, "link"))
      endpoint = LibTmux::Endpoint.new(socket_name: "selected", socket_directory: File.join(root, "link", ".."))
      LibTmux::Server.start(endpoint: endpoint) do |server|
        assert File.socket?(File.join(root, "actual", "tmux-#{Process.uid}", "selected"))
        refute File.exist?(File.join(root, "tmux-#{Process.uid}"))
        assert server.run(["display-message", "-p", "selected"]).success?
      end
    end
  end
end
