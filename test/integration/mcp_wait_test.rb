# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require_relative "../support/process_cursor_support"
require_relative "../support/control_support"
require "libtmux/mcp"
require "async/queue"
require "pty"

class MCPWaitTest < Minitest::Test
  include LibTmuxTest::ProcessCursorSupport
  include LibTmuxTest::ControlSupport

  def test_wait_observes_screen_events_and_initial_process_exit
    with_application do |app, scope, source|
      pane = scope.server.list_panes.first
      target = wire_ref(pane.ref)
      if control_supported?(scope.server)
        ready = signal_after_first_capture(app)
        pending = Async::Task.current.async { call(app, target, {type: "screen_contains", text: "event-visible"}) }
        await_ready(ready, pending)
        refute pending.finished?
        pane.send_text("event-visible")
        result = pending.wait(timeout: 0.5)
        assert result.fetch("ok"), "#{result.inspect}; #{@observation_failure.inspect}"
        assert result.dig("data", "capture", "rows").join.include?("event-visible")
        assert_empty scope.server.list_clients
      else
        assert_screen_wait_polls(app, scope)
      end

      child = pane.split(direction: :vertical, command: [Gem.ruby, "--disable=rubyopt,gems", "-e", "STDIN.gets"])
      ready = signal_after_first_capture(app)
      pending = Async::Task.current.async { call(app, wire_ref(child.ref), {type: "process_exit"}) }
      await_ready(ready, pending)
      child.send_keys("Enter")
      result = pending.wait(timeout: 0.5)
      assert result.fetch("ok"), "#{result.inspect}; #{@observation_failure.inspect}"
      assert_equal "process_exit", result.dig("data", "condition")
      assert_equal "unobserved", result.dig("data", "exit_status")
      assert source.run(["has-session", "-t", "fixture"]).success?
    end
  end

  def test_deadline_and_sdk_cancellation_close_observers_without_terminating_pane
    with_application do |app, scope, source|
      pane = scope.server.list_panes.first
      target = wire_ref(pane.ref)
      if control_supported?(scope.server)
        ready = signal_after_first_capture(app)
        cancellation = ::MCP::Cancellation.new(request_id: 14)
        pending = Async::Task.current.async { call(app, target, {type: "screen_contains", text: "never"}, cancellation: cancellation) }
        await_ready(ready, pending)
        cancellation.cancel
        failure = pending.wait(timeout: 0.5)
        assert_equal "cancelled", failure.dig("error", "code")
        assert_empty scope.server.list_clients
      else
        assert_screen_wait_cancels(app, scope)
      end
      failure = call(app, target, {type: "process_exit"}, timeout: 0.1)
      assert_equal "deadline", failure.dig("error", "code")
      assert scope.server.snapshot.panes.any? { |entry| entry.id == pane.id && !entry.dead }
      assert source.run(["has-session", "-t", "fixture"]).success?
    end
  end

  def test_control_gap_and_repeated_cancellation_retire_all_owned_observers
    with_application(control: true) do |app, scope, source|
      pane = scope.server.list_panes.first
      control = nil
      factory = scope.server.method(:open_control)
      scope.server.define_singleton_method(:open_control) do |**options|
        control = factory.call(**options)
      end
      ready = signal_after_first_capture(app)
      pending = Async::Task.current.async { call(app, wire_ref(pane.ref), {type: "screen_contains", text: "absent"}) }
      await_ready(ready, pending)
      begin
        control.pause_output(pane_id: pane.id, timeout: 0.5)
      rescue LibTmux::ClosedError
        # The observed gap may retire the lane before the pause reply finishes.
      end
      assert_equal "observation_lost", pending.wait(timeout: 0.5).dig("error", "code")
      assert control.closed?

      closing = Async::Queue.new
      held = Async::Queue.new
      ready = signal_after_first_capture(app)
      pending = Async::Task.current.async do
        call(app, wire_ref(pane.ref), {type: "screen_contains", text: "absent"})
      rescue Exception => error
        error
      end
      await_ready(ready, pending)
      original = control.method(:close)
      first = true
      control.define_singleton_method(:close) do |**options|
        if first
          first = false
          closing.enqueue(true)
          held.dequeue
        end
        original.call(**options)
      end
      pending.cancel
      Async::Task.current.with_timeout(0.5) { closing.dequeue }
      pending.cancel
      error = pending.wait(timeout: 0.5)
      assert_instance_of Async::Cancel, error
      assert control.closed?
      assert_raises(Errno::ECHILD) { Process.waitpid(control.pid, Process::WNOHANG) }
      assert_empty scope.server.list_clients
      assert source.run(["has-session", "-t", "fixture"]).success?
    end
  end

  def test_pending_control_retirement_keeps_process_descriptors_until_application_retry
    with_application(control: true) do |app, scope, source|
      pane = scope.server.list_panes.first
      control = nil
      factory = scope.server.method(:open_control)
      scope.server.define_singleton_method(:open_control) { |**options| control = factory.call(**options) }
      ready = signal_after_first_capture(app)
      pending = Async::Task.current.async { call(app, wire_ref(pane.ref), {type: "screen_contains", text: "finish-with-evidence"}) }
      await_ready(ready, pending)
      closer = control.method(:close)
      allow_close = false
      control.define_singleton_method(:close) do |**options|
        raise IOError, "PRIVATE CONTROL CLOSE" unless allow_close

        closer.call(**options)
      end
      begin
        pane.send_text("finish-with-evidence")
        failure = pending.wait(timeout: 0.5)
        assert_equal "transport_error", failure.dig("error", "code"), failure.inspect
        refute_includes JSON.generate(failure), "PRIVATE"
        observer = app.instance_variable_get(:@retiring).first
        refute_nil observer
        identity = observer.instance_variable_get(:@owned).find { |item| item.respond_to?(:io) }
        refute identity.io.closed?
        refute control.closed?
        assert_raises(LibTmux::TransportError) { app.close }
        refute identity.io.closed?
        allow_close = true
        app.close
        assert control.closed?
        assert identity.io.closed?
        assert_empty app.instance_variable_get(:@retiring)
        assert source.run(["has-session", "-t", "fixture"]).success?
      ensure
        allow_close = true
      end
    end
  end

  def test_application_close_cancels_and_joins_an_active_wait_before_returning
    with_application(control: true) do |app, scope, source|
      pane = scope.server.list_panes.first
      ready = signal_after_first_capture(app)
      pending = Async::Task.current.async { call(app, wire_ref(pane.ref), {type: "screen_contains", text: "not-present"}) }
      await_ready(ready, pending)
      refute pending.finished?
      app.close
      assert pending.finished?, "Application.close must join the admitted request's observer cleanup"
      assert_equal "cancelled", pending.wait(timeout: 0.5).dig("error", "code")
      assert_empty app.instance_variable_get(:@observers)
      assert_empty app.instance_variable_get(:@retiring)
      assert_empty scope.server.list_clients
      assert source.run(["has-session", "-t", "fixture"]).success?
    ensure
      pending.cancel unless pending&.finished?
    end
  end

  def test_application_close_keeps_request_ownership_through_repeated_cancellation
    with_application(control: true) do |app, scope, source|
      pane = scope.server.list_panes.first
      control = nil
      factory = scope.server.method(:open_control)
      scope.server.define_singleton_method(:open_control) { |**options| control = factory.call(**options) }
      ready = signal_after_first_capture(app)
      pending = Async::Task.current.async { call(app, wire_ref(pane.ref), {type: "screen_contains", text: "not-present"}) }
      await_ready(ready, pending)
      closing, release, waiting = Async::Queue.new, Async::Queue.new, Async::Queue.new
      original = control.method(:close)
      control.define_singleton_method(:close) do |**options|
        closing.enqueue(true)
        release.dequeue
        original.call(**options)
      end
      changed = app.instance_variable_get(:@calls_changed)
      original_wait = changed.method(:wait)
      changed.define_singleton_method(:wait) do
        waiting.enqueue(true)
        original_wait.call
      end
      closer = Async::Task.current.async do
        app.close
      rescue Exception => error
        error
      end
      Async::Task.current.with_timeout(0.5) { closing.dequeue; waiting.dequeue }
      2.times do
        closer.cancel
        Async::Task.current.with_timeout(0.5) { waiting.dequeue }
      end
      release.enqueue(true)
      assert_instance_of Async::Cancel, closer.wait(timeout: 0.5)
      assert pending.finished?
      assert_equal "cancelled", pending.wait(timeout: 0.5).dig("error", "code")
      assert control.closed?
      assert_empty app.instance_variable_get(:@calls)
      assert_empty app.instance_variable_get(:@observers)
      app.close
      assert source.run(["has-session", "-t", "fixture"]).success?
    ensure
      release&.enqueue(true)
      pending.cancel unless pending&.finished?
    end
  end

  def test_wait_finds_text_that_the_pane_wrapped_across_rows
    with_application do |app, scope, _source|
      pane = scope.server.list_panes.first
      width = scope.server.snapshot.panes.find { |entry| entry.id == pane.id }.width
      ready = signal_after_first_capture(app)
      pending = Async::Task.current.async { call(app, wire_ref(pane.ref), {type: "screen_contains", text: "ABCDEFGHIJ"}) }
      await_ready(ready, pending)
      refute pending.finished?
      # The echoed line is wider than the pane, so tmux wraps it between E and F.
      pane.send_text("x" * (width - 5) + "ABCDEFGHIJ")
      result = pending.wait(timeout: 1)
      assert result.fetch("ok"), "#{result.inspect}; #{@observation_failure.inspect}"
      assert result.dig("data", "capture", "rows").join.include?("ABCDEFGHIJ")
    end
  end

  def test_wait_for_screen_text_ends_as_pane_died_with_the_output_so_far_when_the_pane_dies
    with_application do |app, scope, source|
      child = scope.server.list_panes.first.split(direction: :vertical,
        command: ["/bin/sh", "-c", "echo output-so-far; exec cat"])
      ready = signal_after_first_capture(app)
      pending = Async::Task.current.async { call(app, wire_ref(child.ref), {type: "screen_contains", text: "never-printed"}) }
      await_ready(ready, pending)
      refute pending.finished?
      child.kill
      failure = pending.wait(timeout: 1)
      assert_pane_died(failure)
      assert source.run(["has-session", "-t", "fixture"]).success?
    end
  end

  def test_wait_for_screen_text_ends_as_pane_died_with_the_output_so_far_when_the_server_is_killed
    with_application do |app, scope, source|
      # The pane ignores the hangup that follows the server, so only the
      # server's own exit tells the wait that the screen is gone.
      child = scope.server.list_panes.first.split(direction: :vertical,
        command: ["/bin/sh", "-c", "trap '' HUP; echo output-so-far; while :; do sleep 0.2; done"])
      pid = scope.server.snapshot.panes.find { |entry| entry.id == child.id }.pid
      begin
        ready = signal_after_first_capture(app)
        pending = Async::Task.current.async { call(app, wire_ref(child.ref), {type: "screen_contains", text: "never-printed"}) }
        await_ready(ready, pending)
        refute pending.finished?
        source.run(["kill-server"])
        assert_pane_died(pending.wait(timeout: 1))
      ensure
        Process.kill("KILL", pid)
      end
    end
  end

  def test_wait_ends_as_pane_died_when_a_stopped_client_keeps_the_killed_server_alive
    with_application do |app, scope, _source|
      child = scope.server.list_panes.first.split(direction: :vertical,
        command: ["/bin/sh", "-c", "trap '' HUP; echo output-so-far; while :; do sleep 0.2; done"])
      pid = scope.server.snapshot.panes.find { |entry| entry.id == child.id }.pid
      reader, writer, client = PTY.spawn({"TMUX" => nil}, @fixture.executable, "-S", @fixture.socket_path, "attach", "-t", "fixture")
      killer = nil
      begin
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        sleep 0.02 until scope.server.list_clients.any? { |entry| entry.fetch(:pid) == client } ||
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        ready = signal_after_first_capture(app)
        pending = Async::Task.current.async { call(app, wire_ref(child.ref), {type: "screen_contains", text: "never-printed"}) }
        await_ready(ready, pending)
        refute pending.finished?
        # tmux stays up until every client leaves, and this one is stopped.
        Process.kill("STOP", client)
        killer = Process.spawn({"TMUX" => nil}, @fixture.executable, "-S", @fixture.socket_path, "kill-server",
          in: File::NULL, out: File::NULL, err: File::NULL)
        assert_pane_died(pending.wait(timeout: 2))
      ensure
        begin
          Process.kill("CONT", client)
          Process.kill("KILL", client)
        rescue Errno::ESRCH
          nil
        end
        [reader, writer].each { |io| io.close unless io.closed? }
        Process.wait(client)
        Process.wait(killer) if killer
        Process.kill("KILL", pid)
      end
    end
  end

  def test_the_daemon_probe_behind_wait_results_fires_no_hook
    with_application do |app, scope, source|
      %w[command-error after-display-message after-list-panes].each do |hook|
        # command-error is absent from older builds, which reject the hook.
        result = source.run(["set-hook", "-g", hook, "set-option -g @hook-fired #{hook}"])
        assert result.success? || hook == "command-error", result.stderr
      end
      observer = LibTmux::MCP.const_get(:Observation).new(server: scope.server, arguments: {}, timeout: 1, cancel: nil,
        max_snapshot_bytes: 1 << 16)
      assert_equal :alive, observer.__send__(:daemon_state)
      assert_equal "", source.run(["show-options", "-gqv", "@hook-fired"]).stdout.to_s
      # A command that does fire hooks proves the hooks above are live.
      source.run(["display-message", "-p", "x"])
      refute_equal "", source.run(["show-options", "-gqv", "@hook-fired"]).stdout.to_s
    ensure
      observer&.close
    end
  end

  def test_a_failed_daemon_probe_is_not_a_dead_daemon
    with_application do |app, scope, _source|
      observer = LibTmux::MCP.const_get(:Observation).new(server: scope.server, arguments: {}, timeout: 1, cancel: nil,
        max_snapshot_bytes: 1 << 16)
      probe = ->(failure) do
        scope.server.define_singleton_method(:run) do |argv, **|
          raise failure if argv.first == "run-shel"

          super(argv)
        end
      end
      probe.call(Errno::EMFILE.new)
      assert_equal :unknown, observer.__send__(:daemon_state)
      refute observer.__send__(:ended?, Struct.new(:io, :peer) { def exited? = false }.new)
      reply = Struct.new(:stderr, :stdout, :success?)
      scope.server.define_singleton_method(:run) { |*, **| reply.new("server exited unexpectedly\n", "", false) }
      assert_equal :gone, observer.__send__(:daemon_state)
      scope.server.define_singleton_method(:run) { |*, **| reply.new("something else\n", "", false) }
      assert_equal :unknown, observer.__send__(:daemon_state)
    ensure
      observer&.close
    end
  end

  def test_wait_reports_a_lost_stream_not_pane_died_when_the_probe_cannot_run
    with_application do |app, scope, source|
      pane = scope.server.list_panes.first
      next unless control_supported?(scope.server)

      ready = signal_after_first_capture(app)
      pending = Async::Task.current.async { call(app, wire_ref(pane.ref), {type: "screen_contains", text: "never-printed"}) }
      await_ready(ready, pending)
      scope.server.define_singleton_method(:run) do |argv, **options|
        raise Errno::EMFILE if argv.first == "run-shel"

        super(argv, **options)
      end
      clients = scope.server.list_clients
      assert source.run(["detach-client", "-t", clients.first.fetch(:name)]).success?
      failure = pending.wait(timeout: 2)
      assert_equal "observation_lost", failure.dig("error", "code"), failure.inspect
    end
  end

  def test_wait_reports_a_lost_stream_when_the_control_client_detaches_from_a_live_pane
    with_application do |app, scope, source|
      pane = scope.server.list_panes.first
      ready = signal_after_first_capture(app)
      pending = Async::Task.current.async { call(app, wire_ref(pane.ref), {type: "screen_contains", text: "never-printed"}) }
      await_ready(ready, pending)
      if control_supported?(scope.server)
        clients = scope.server.list_clients
        assert_equal 1, clients.length
        assert source.run(["detach-client", "-t", clients.first.fetch(:name)]).success?
        failure = pending.wait(timeout: 1)
        assert_equal "observation_lost", failure.dig("error", "code"), failure.inspect
        assert_equal "observed", failure.dig("error", "delivery")
        assert scope.server.snapshot.panes.any? { |entry| entry.id == pane.id && !entry.dead }
      else
        # Below 3.7 the wait polls and holds no client that could drop.
        assert_empty scope.server.list_clients
        refute pending.finished?
        pending.cancel
      end
      assert source.run(["has-session", "-t", "fixture"]).success?
    end
  end

  private

  def await_ready(ready, pending)
    Async::Task.current.with_timeout(0.5) { ready.wait }
  rescue Async::TimeoutError
    pending.wait if pending.finished?
    raise
  end

  def signal_after_first_capture(app)
    signal = ::Async::Notification.new
    test = self
    @observation_failure = nil
    factory = app.method(:observation)
    app.define_singleton_method(:observation) do |*arguments|
      observer = factory.call(*arguments)
      wait = observer.method(:wait)
      observer.define_singleton_method(:wait) do
        wait.call
      rescue LibTmux::Error => error
        test.instance_variable_set(:@observation_failure,
          {class: error.class.name, message: error.message, phase: error.phase, cleanup_errors: error.cleanup_errors})
        raise
      end
      original = observer.method(:read_rows)
      first = true
      observer.define_singleton_method(:read_rows) do |*values|
        result = original.call(*values)
        signal.signal if first
        first = false
        result
      end
      observer
    end
    signal
  end

  # Below 3.7 a screen wait polls the pane and attaches no control client.
  def assert_screen_wait_polls(app, scope)
    pane = scope.server.list_panes.first
    ready = signal_after_first_capture(app)
    pending = Async::Task.current.async { call(app, wire_ref(pane.ref), {type: "screen_contains", text: "polled-visible"}) }
    await_ready(ready, pending)
    refute pending.finished?
    assert_empty scope.server.list_clients
    pane.send_text("polled-visible")
    result = pending.wait(timeout: 1)
    assert result.fetch("ok"), result.inspect
    assert result.dig("data", "capture", "rows").join.include?("polled-visible")
    assert_empty scope.server.list_clients
  end

  def assert_screen_wait_cancels(app, scope)
    pane = scope.server.list_panes.first
    ready = signal_after_first_capture(app)
    cancellation = ::MCP::Cancellation.new(request_id: 15)
    pending = Async::Task.current.async do
      call(app, wire_ref(pane.ref), {type: "screen_contains", text: "never-visible"}, cancellation: cancellation)
    end
    await_ready(ready, pending)
    cancellation.cancel
    assert_equal "cancelled", pending.wait(timeout: 0.5).dig("error", "code")
    assert_empty scope.server.list_clients
  end

  def assert_pane_died(failure)
    assert_equal "pane_died", failure.dig("error", "code"), failure.inspect
    assert_equal "observed", failure.dig("error", "delivery")
    assert failure.dig("error", "capture", "rows").join.include?("output-so-far"), failure.inspect
  end

  def with_application(control: false)
    LibTmuxTest::TmuxFixture.open do |fixture|
      @fixture = fixture
      LibTmux::Server.open(socket_path: fixture.socket_path, executable: fixture.executable) do |source|
        Async do |task|
          LibTmux::Async.open(server: source, parent: task) do |scope|
            app = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: "test", enabled_tools: ["tmux_wait"])
            begin
              require_process_cursor_support(scope)
              if control && !control_supported?(scope.server)
                assert_screen_wait_polls(app, scope)
              else
                yield app, scope, source
              end
            ensure
              app.close
            end
          end
        end.wait
      end
    end
  end

  def call(app, target, condition, cancellation: nil, **options)
    app.call("tmux_wait", {target: target, condition: condition, **options}, cancellation: cancellation).structured_content
  end

  def wire_ref(ref)
    {"generation" => ref.binding_key, "kind" => ref.kind.to_s, "id" => ref.id}
  end
end
