# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require_relative "../support/process_cursor_support"
require "libtmux/mcp"
require "shellwords"

class MCPCursorIdentityTest < Minitest::Test
  include LibTmuxTest::ProcessCursorSupport
  def test_respawn_between_descriptor_acquisition_and_guard_rejects_even_if_old_process_survives
    with_application do |app, scope, fixture|
      listener = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "old-process"))
      program = 'require "socket"; trap("HUP") {}; socket=UNIXSocket.new(ARGV[0]); socket.puts("ready"); socket.gets'
      pane = scope.server.list_panes.first.split(direction: :vertical,
        command: [Gem.ruby, "--disable=rubyopt,gems", "-e", program, listener.path])
      connection = listener.accept
      assert_equal "ready\n", connection.gets
      klass = LibTmux::MCP.const_get(:ProcessIdentity)
      original = klass.method(:acquire)
      retained = nil
      klass.define_singleton_method(:acquire) do |*arguments, **keywords|
        identity = original.call(*arguments, **keywords)
        retained = identity.retain
        pane.respawn(command: ["cat"], kill: true)
        identity
      end
      begin
        failure = capture(app, pane, track: true)
        assert_equal "stale_target", failure.dig("error", "code"), failure.inspect
        refute retained.exited?, "the old process deliberately survives PTY closure"
        assert_empty app.instance_variable_get(:@captures)
      ensure
        klass.define_singleton_method(:acquire, original)
        connection.puts("exit") unless connection.closed?
        connection.read unless connection.closed?
        retained&.close
      end
    ensure
      connection&.close
      listener&.close
    end
  end

  def test_reaped_leader_with_draining_output_rejects_reused_pid_and_foreign_identity
    with_application do |app, scope, fixture|
      listener = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "leader"))
      program = 'require "socket"; socket=UNIXSocket.new(ARGV[0]); socket.puts("ready"); socket.gets; STDOUT.write("x" * 1048576); STDOUT.flush; exit! 0'
      pane = scope.server.list_panes.first.split(direction: :vertical,
        command: [Gem.ruby, "--disable=rubyopt,gems", "-e", program, listener.path])
      pane.options.set("remain-on-exit", true)
      connection = listener.accept
      assert_equal "ready\n", connection.gets
      sink_listener = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "pipe-sink"))
      sink_program = 'require "socket"; socket=UNIXSocket.new(ARGV[0]); socket.puts("ready"); socket.gets; STDIN.read'
      pane.pipe(shell_command: [Gem.ruby, "--disable=rubyopt,gems", "-e", sink_program, sink_listener.path].shelljoin)
      sink = sink_listener.accept
      assert_equal "ready\n", sink.gets
      connection.puts("write-and-exit")
      assert_equal "", connection.read
      status = scope.server.run(["display-message", "-p", "-t", pane.id, '#{pane_dead}|#{pane_dead_status}|#{pane_dead_signal}']).text
      assert_equal "0|0|\n", status, "the leader is reaped while its output pipe still has queued bytes"
      klass = LibTmux::MCP.const_get(:ProcessIdentity)
      original = klass.method(:acquire)
      # Emulate the kernel-reuse hazard with a real live descriptor but the
      # stale numeric pane PID. The guard must reject tmux's death status.
      klass.define_singleton_method(:acquire) do |*arguments, **keywords|
        identity = original.call(*arguments, **keywords.merge(pane_pid: Process.pid))
        identity.instance_variable_set(:@pid, keywords.fetch(:pane_pid))
        identity
      end
      begin
        failure = capture(app, pane, track: true)
        assert_equal "stale_target", failure.dig("error", "code"), failure.inspect
        assert_empty app.instance_variable_get(:@captures)
      ensure
        klass.define_singleton_method(:acquire, original)
        sink.puts("drain") unless sink.closed?
      end
      namespace = klass.method(:procfs_namespace)
      if RUBY_PLATFORM.include?("darwin")
        klass.define_singleton_method(:acquire) do |*arguments, **keywords|
          original.call(*arguments, **keywords.merge(server_pid: Process.pid))
        end
      else
        klass.define_singleton_method(:procfs_namespace) { File.open("/proc/self/ns/mnt") }
      end
      begin
        failure = capture(app, scope.server.list_panes.find { |item| item.id != pane.id }, track: true)
        assert_equal "unsupported", failure.dig("error", "code")
      ensure
        klass.define_singleton_method(:procfs_namespace, namespace)
        klass.define_singleton_method(:acquire, original)
      end
    ensure
      connection&.close
      listener&.close
      sink&.close
      sink_listener&.close
    end
  end

  def test_process_death_remains_readable_after_owned_child_is_reaped
    with_application do |_app, scope, fixture|
      listener = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "retained-exit"))
      code = 'require "socket"; UNIXSocket.open(ARGV.fetch(0)) { |io| io.puts(Process.pid); io.read(1) }'
      request = ::Async::Task.current.async do
        scope.__send__(:execute, [Gem.ruby, "--disable=rubyopt,gems", "-e", code, listener.path])
      end
      connection = pid = nil
      ::Async::Task.current.with_timeout(0.5) do
        connection = listener.accept
        pid = Integer(connection.gets, 10)
      end
      snapshot = scope.server.snapshot
      identity = LibTmux::MCP.const_get(:ProcessIdentity).acquire(scope.server,
        server_pid: snapshot.server_info.fetch(:pid), pane_pid: pid,
        budget: scope.server.__send__(:operation_budget, 0.5, nil))
      klass = LibTmux::MCP.const_get(:ProcessIdentity)
      native = klass.method(:native)
      faults = [:interrupted]
      klass.define_singleton_method(:native) do |name, *signature|
        function = native.call(name, *signature)
        next function unless name == "poll"

        lambda do |*arguments|
          case faults.shift
          when :interrupted
            Fiddle.last_error = Errno::EINTR::Errno
            -1
          when :failed
            Fiddle.last_error = Errno::EIO::Errno
            -1
          when :invalid
            arguments.first[6, 2] = [0x20].pack("s")
            1
          else
            function.call(*arguments)
          end
        end
      end
      refute identity.exited?
      assert_empty faults
      connection.write("x")
      assert request.wait.success?
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      faults << :interrupted
      2.times { assert identity.exited?, "terminal process readiness was consumed" }
      [[:interrupted, :interrupted], [:failed], [:invalid]].each do |sequence|
        faults.replace(sequence)
        error = assert_raises(LibTmux::TransportError) { identity.exited? }
        assert_equal :read, error.phase
        assert_empty faults
      end
    ensure
      klass.define_singleton_method(:native, native) if native
      identity&.close
      connection&.close
      listener&.close
      begin
        request&.cancel unless request&.finished?
        request&.wait
      rescue LibTmux::Cancelled, ::Async::Cancel
        nil
      end
    end
  end

  def test_retained_descriptors_share_cursor_branches_and_close_with_eviction_expiry_and_application
    with_application(max_captures: 2) do |app, scope, fixture|
      pane = scope.server.list_panes.first
      first = capture(app, pane, track: true).fetch("data")
      entry = app.instance_variable_get(:@captures).fetch(first.fetch("next_cursor"))
      identity = entry.process
      branch = capture(app, pane, cursor: first.fetch("next_cursor")).fetch("data")
      assert_same identity, app.instance_variable_get(:@captures).fetch(branch.fetch("next_cursor")).process
      capture(app, pane, track: true)
      refute identity.io.closed?, "evicting one immutable branch must preserve its other owner"
      capture(app, pane, track: true)
      assert identity.io.closed?
      assert identity.peer.closed?
      entries = app.instance_variable_get(:@captures).values
      app.define_singleton_method(:clock) { Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60 }
      assert_equal "stale_cursor", capture(app, pane, cursor: branch.fetch("next_cursor")).dig("error", "code")
      entries.each { |retained| assert retained.process.io.closed? }
      capture(app, pane, track: true)
      entries = app.instance_variable_get(:@captures).values
      app.close
      entries.each { |retained| assert retained.process.io.closed? }
    end
  end

  def test_application_close_attempts_every_descriptor_and_retains_failed_retirement_for_retry
    with_application do |app, scope, fixture|
      pane = scope.server.list_panes.first
      2.times { assert capture(app, pane, track: true).fetch("ok") }
      entries = app.instance_variable_get(:@captures).values
      io = entries.first.process.io
      original = io.method(:close)
      first = true
      io.define_singleton_method(:close) do
        if first
          first = false
          raise IOError, "PRIVATE CLOSE SENTINEL"
        end
        original.call
      end
      error = assert_raises(LibTmux::TransportError) { app.close }
      refute_includes error.message, "PRIVATE"
      refute io.closed?
      assert entries.first.process.peer.closed?
      assert entries.last.process.io.closed?
      assert entries.last.process.peer.closed?
      app.close
      assert io.closed?
      assert_empty app.instance_variable_get(:@captures)
    end
  end

  def test_acquisition_cleanup_failure_is_sanitized_and_keeps_retry_ownership
    with_application do |app, scope, fixture|
      pane = scope.server.list_panes.first
      held = nil
      allow_close = false
      refuse_close = lambda do |io|
        held = io
        closer = io.method(:close)
        io.define_singleton_method(:close) do
          raise IOError, "PRIVATE OBSERVER CLEANUP" unless allow_close

          closer.call
        end
      end
      restore = if RUBY_PLATFORM.include?("darwin")
        identity = LibTmux::MCP.const_get(:ProcessIdentity)
        validate = identity.instance_method(:ensure_live!)
        identity.define_method(:ensure_live!) do
          validate.bind_call(self)
          refuse_close.call(io)
          raise LibTmux::TransportError.new("identity acquisition interrupted", phase: :admission)
        end
        -> { identity.define_method(:ensure_live!, validate) }
      else
        constructor = Socket.method(:new)
        Socket.define_singleton_method(:new) do |*arguments|
          constructor.call(*arguments).tap { |socket| refuse_close.call(socket) }
        end
        -> { Socket.define_singleton_method(:new, constructor) }
      end
      begin
        result = capture(app, pane, track: true)
        assert_equal "transport_error", result.dig("error", "code"), result.inspect
        refute_includes JSON.generate(result), "PRIVATE"
        refute held.closed?
        refute_empty app.instance_variable_get(:@retiring)
        assert_equal "capacity", capture(app, pane, track: true).dig("error", "code")
        allow_close = true
        app.close
        assert held.closed?
        assert_empty app.instance_variable_get(:@retiring)
        assert_empty app.instance_variable_get(:@observers)
      ensure
        allow_close = true
        restore.call
      end
    end
  end

  private

  def capture(app, pane, **options)
    ref = pane.ref
    app.call("tmux_capture", {target: {generation: ref.binding_key, kind: "pane", id: ref.id}, **options}).structured_content
  end

  def with_application(**options)
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path, executable: fixture.executable) do |source|
        Async do |task|
          LibTmux::Async.open(server: source, parent: task) do |scope|
            app = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test", enabled_tools: ["tmux_capture"], **options)
            begin
              yield app, scope, fixture if require_process_cursor_support(app, scope)
            ensure
              app.close
            end
          end
        end.wait
      end
    end
  end
end
