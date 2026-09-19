# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux/async"
require "socket"

class AsyncTest < Minitest::Test
  def test_process_facade_yields_to_the_client_that_releases_a_wait
    assert LibTmux::Async.respond_to?(:open), "Async scope is missing"
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |source|
        ref = source.list_panes.first.ref
        Async do |parent|
          parent.with_timeout(0.5) do
            LibTmux::Async.open(parent: parent, server: source) do |scope|
              assert_equal ref, scope.server.pane(ref).ref
              waiting = parent.async do
                scope.server.run(["wait-for", "-S", "async-ready", ";", "wait-for", "async-held"])
              end
              assert scope.server.run(["wait-for", "async-ready"]).success?
              assert scope.server.run(["wait-for", "-S", "async-held"]).success?
              result = waiting.wait
              assert result.success?
              assert_equal :observed, result.delivery
              assert_raises(Errno::ECHILD) { Process.waitpid(result.pid, Process::WNOHANG) }
            end
          end
        end.wait
        assert source.run(["has-session", "-t", "$0"]).success?
      end
    end
  end

  def test_binary_pipe_flood_and_partial_input_stay_on_the_scheduler_thread
    with_scope do |scope, parent|
      input = "\0\xFF".b * 131_072
      owner = Thread.current
      owners = []
      trace = TracePoint.new(:call, :c_call) do |event|
        if [:read_nonblock, :write_nonblock].include?(event.method_id) &&
            caller_locations(1, 8).any? { |location| location.path.end_with?("libtmux/async/process.rb") }
          owners << Thread.current
        end
      end
      code = <<~RUBY
        STDIN.binmode; STDOUT.binmode; STDERR.binmode
        out = Thread.new { STDOUT.write("\\xFF".b * 131072) }
        err = Thread.new { STDERR.write("\\xFE".b * 81920) }
        data = STDIN.read
        out.join; err.join
        exit(data == "\\0\\xFF".b * 131072 ? 17 : 99)
      RUBY
      trace.enable
      result = scope.__send__(:execute, ruby(code), input: input, timeout: 0.5)
      trace.disable
      assert_equal 17, result.status.exitstatus
      assert_equal "\xFF".b * 131_072, result.stdout
      assert_equal "\xFE".b * 81_920, result.stderr
      assert result.stdout.frozen?
      assert result.stderr.frozen?
      refute_empty owners
      assert owners.all? { |thread| thread.equal?(owner) }, "a pipe reader or writer escaped the scheduler thread"
      assert_raises(Errno::ECHILD) { Process.waitpid(result.pid, Process::WNOHANG) }
    ensure
      trace&.disable
    end
  end

  def test_ordered_map_retains_input_order_after_out_of_order_completion
    with_scope do |scope, parent|
      assert scope.respond_to?(:map), "bounded ordered map is missing"
      released = Queue.new
      completed = []
      results = scope.map([0, 1], concurrency: 2) do |index|
        if index.zero?
          released.pop
        end
        scope.server.run(["display-message", "-p", index.to_s]).tap do
          completed << index
          released << true unless index.zero?
        end
      end
      assert_equal ["0\n", "1\n"], results.map(&:text)
      assert_equal [1, 0], completed
      assert results.all?(&:success?)
    end
  end

  def test_admission_caps_four_children_and_thirty_two_requests
    with_scope do |scope, parent, fixture|
      listener = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "async-admission"))
      code = 'require "socket"; UNIXSocket.open(ARGV.fetch(0)) { |io| io.write(Process.pid.to_s + "\\n"); io.read(1) }'
      requests = 32.times.map do
        parent.async do
          scope.__send__(:execute, ruby(code) + [listener.path])
        rescue LibTmux::Cancelled => failure
          failure
        end
      end
      clients = 4.times.map { listener.accept }
      pids = clients.map { |client| Integer(client.gets, 10) }
      assert_equal :wait_readable, listener.accept_nonblock(exception: false), "more than four children were dispatched"
      error = assert_raises(LibTmux::CapacityError) { scope.__send__(:execute, ruby("exit")) }
      assert_equal :not_sent, error.delivery
      requests.drop(4).each(&:cancel)
      requests.drop(4).each do |request|
        failure = request.wait
        assert_instance_of LibTmux::Cancelled, failure
        assert_equal :not_sent, failure.delivery
        assert_nil failure.pid
      end
      clients.each { |client| client.write("x") }
      assert requests.take(4).all? { |request| request.wait.success? }
      pids.each { |pid| assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) } }
    ensure
      clients&.each(&:close)
      listener&.close
    end
  end

  def test_repeated_caller_cancellation_reaps_a_child_ignoring_term
    with_scope(cleanup_timeout: 0.08) do |scope, parent, fixture|
      listener = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "async-cancel"))
      reaping, notify = IO.pipe
      release = Queue.new
      observer = nil
      code = <<~RUBY
        require "socket"
        UNIXSocket.open(ARGV.fetch(0)) do |io|
          io.sync = true
          trap("TERM") {}
          io.write(Process.pid.to_s + "\\n")
          io.read(1)
        end
      RUBY
      request = parent.async do
        scope.__send__(:execute, ruby(code) + [listener.path])
      rescue LibTmux::Error => failure
        failure
      end
      peer = listener.accept
      pid = Integer(peer.gets, 10)
      trace = TracePoint.new(:c_call) do |event|
        next unless event.method_id == :wait2 && !observer

        observer = Thread.current
        notify.syswrite("reaping\n")
        release.pop
      end
      trace.enable
      request.cancel
      assert_equal "reaping\n", reaping.gets
      request.cancel
      release << true
      failure = request.wait
      assert_instance_of LibTmux::Cancelled, failure
      assert_equal :possibly_sent, failure.delivery
      assert_equal pid, failure.pid
      assert_empty failure.cleanup_errors
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      assert scope.server.run(["has-session", "-t", "$0"]).success?
    ensure
      trace&.disable
      release << true if release
      observer&.join(0.5)
      reaping&.close
      notify&.close
      peer&.close
      listener&.close
    end
  end

  def test_wrong_thread_closed_binding_and_byte_admission_are_refused
    with_scope(max_queue_bytes: 64) do |scope, parent|
      failure = Thread.new do
        scope.server.run(["list-sessions"])
      rescue LibTmux::ClosedError => error
        error
      end.value
      assert_instance_of LibTmux::ClosedError, failure
      error = assert_raises(LibTmux::CapacityError) { scope.__send__(:execute, ruby("exit"), input: "x" * 65) }
      assert_equal :not_sent, error.delivery
      assert_nil error.pid
      error = assert_raises(LibTmux::DeadlineExceeded) { scope.__send__(:execute, ruby("exit"), timeout: 0) }
      assert_equal :not_sent, error.delivery
      scope.close
      assert_raises(LibTmux::ClosedError) { scope.server.list_panes }
    end
  end

  def test_map_failure_survives_repeated_cancellation_while_siblings_retire
    with_scope(cleanup_timeout: 0.08) do |scope, parent, fixture|
      listener = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "async-map-error"))
      reaping, notify = IO.pipe
      release = Queue.new
      observer = nil
      original = RuntimeError.new("first map failure")
      peer = pid = nil
      trace = TracePoint.new(:c_call) do |event|
        next unless event.method_id == :wait2 && !observer

        observer = Thread.current
        notify.syswrite("reaping\n")
        release.pop
      end
      trace.enable
      code = <<~RUBY
        require "socket"
        UNIXSocket.open(ARGV.fetch(0)) do |io|
          io.sync = true
          trap("TERM") {}
          io.write(Process.pid.to_s + "\\n")
          io.read(1)
        end
      RUBY
      failure = assert_raises(RuntimeError) do
        scope.map([0, 1], concurrency: 2) do |index|
          if index.zero?
            scope.__send__(:execute, ruby(code) + [listener.path])
          else
            peer = listener.accept
            pid = Integer(peer.gets, 10)
            parent.async do
              assert_equal "reaping\n", reaping.gets
              parent.cancel
              parent.cancel
            ensure
              release << true
            end
            raise original
          end
        end
      end
      assert_same original, failure
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      assert scope.server.run(["has-session", "-t", "$0"]).success?
    ensure
      trace&.disable
      release << true if release
      observer&.join(0.5)
      reaping&.close
      notify&.close
      peer&.close
      listener&.close
    end
  end

  def test_map_cancel_delivery_uses_the_same_bounded_retirement_deadline
    with_scope(cleanup_timeout: 0.002) do |scope, _parent|
      ready, waiting = ::Async::Notification.new, ::Async::Notification.new
      original = RuntimeError.new("original map failure")
      worker = started = nil
      attempts = 0
      trace = TracePoint.new(:call) do |event|
        next unless event.method_id == :cancel && event.self.equal?(worker)

        started ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        attempts += 1
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 0.05
          raise RuntimeError, "cancellation delivery ignored the cleanup deadline"
        end
        raise ::Async::Cancel
      end
      failure = assert_raises(RuntimeError) do
        trace.enable do
          scope.map([0, 1], concurrency: 2) do |index|
            if index.zero?
              ready.wait until worker
              raise original
            end
            worker = ::Async::Task.current
            ready.signal
            waiting.wait
          end
        end
      end
      assert_same original, failure
      assert_operator attempts, :>=, 1
      assert failure.async_cleanup_errors.any? { |detail| detail.include?("cancellation") }
    ensure
      trace&.disable
      worker&.cancel unless worker&.finished?
    end
  end

  def test_observed_exit_wins_token_cancellation_before_reaping
    with_scope do |scope, parent|
      cancel = LibTmux::Internal::Cancellation.new
      released = Queue.new
      handed_off = false
      observer = nil
      trace = TracePoint.new(:call, :return, :c_call) do |event|
        if event.event == :return && event.defined_class == LibTmux::Internal::OwnedChild &&
            event.method_id == :finish_signalling && !handed_off
          handed_off = true
          cancel.cancel
        elsif event.event == :c_call && event.method_id == :wait2 && !observer
          observer = Thread.current
          released.pop
        elsif event.event == :call && event.method_id == :io_wait && handed_off
          released << true
        end
      end
      trace.enable
      result = scope.__send__(:execute, ruby('STDOUT.write("done")'), cancel: cancel)
      trace.disable
      assert_equal "done", result.stdout
      assert result.success?
      assert_raises(Errno::ECHILD) { Process.waitpid(result.pid, Process::WNOHANG) }
    ensure
      trace&.disable
      released << true if released
      observer&.join(0.5)
      cancel&.close
    end
  end

  def test_output_and_map_retention_limits_fail_with_owned_cleanup
    with_scope(stdout_limit: 64) do |scope, parent|
      error = assert_raises(LibTmux::CapacityError) { scope.__send__(:execute, ruby('STDOUT.write("x" * 65536)')) }
      assert_equal :possibly_sent, error.delivery
      assert_raises(Errno::ECHILD) { Process.waitpid(error.pid, Process::WNOHANG) }
      assert_empty error.cleanup_errors
      error = assert_raises(LibTmux::CapacityError) { scope.map([1, 2], max_bytes: 8) { "x" * 5 } }
      assert_equal :observed, error.delivery
    end
  end

  def test_map_nested_results_cannot_bypass_byte_or_structure_limits
    with_scope do |scope, parent|
      error = assert_raises(LibTmux::CapacityError) { scope.map([1], max_bytes: 16) { {payload: ["x" * 32]} } }
      assert_equal :observed, error.delivery
      cycle = []
      cycle << cycle
      assert_raises(LibTmux::CapacityError) { scope.map([1]) { cycle } }
      value = Object.new
      assert_raises(LibTmux::UnsupportedFeatureError) { scope.map([1]) { value } }
      assert_equal [value], scope.map([1], result_bytes: ->(_) { 8 }) { value }
    end
  end

  def test_request_constructor_failure_releases_reserved_admission
    with_scope(max_requests: 1) do |scope, parent|
      original = RuntimeError.new("request construction failed")
      driver = LibTmux::Async.const_get(:ProcessDriver, false)
      trace = TracePoint.new(:call) do |event|
        raise original if event.defined_class == driver && event.method_id == :initialize
      end
      trace.enable
      failure = assert_raises(RuntimeError) { scope.server.run(["list-sessions"]) }
      trace.disable
      assert_same original, failure
      assert scope.server.run(["has-session", "-t", "$0"]).success?
    ensure
      trace&.disable
    end
  end

  def test_control_wait_and_guarded_replies_progress_with_independent_processes
    assert defined?(LibTmux::Async::ControlConnection), "scheduler-owned control transport is missing"
    with_scope do |scope, parent|
      owner = Thread.current
      io_owners = []
      trace = TracePoint.new(:call, :c_call) do |event|
        if [:read_nonblock, :write_nonblock].include?(event.method_id) &&
            caller_locations(1, 8).any? { |location| location.path.end_with?("libtmux/async/control.rb") }
          io_owners << Thread.current
        end
      end
      trace.enable
      session = scope.server.list_sessions.first.ref
      scope.server.open_control(session: session) do |control|
        waiting = parent.async { control.exchange('wait-for -S async-control-ready ; wait-for async-control-held ; display-message -p complete') }
        assert scope.server.run(["wait-for", "async-control-ready"]).success?
        assert scope.server.run(["wait-for", "-S", "async-control-held"]).success?
        reply = waiting.wait
        assert_equal :observed, reply.delivery
        assert_equal "complete\n", reply.blocks.last.body
        assert reply.blocks.all?(&:frozen?)
        pid = control.pid
        control.close
        assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      end
      trace.disable
      refute_empty io_owners
      assert io_owners.all? { |thread| thread.equal?(owner) }, "control pipe I/O escaped its scheduler thread"
      assert scope.server.run(["has-session", "-t", "$0"]).success?
    ensure
      trace&.disable
    end
  end

  def test_control_shares_guard_attribution_and_fails_closed_on_corruption
    with_scope do |scope, parent|
      scope.server.run(["set-option", "-s", "command-alias[99]", "probe=display-message -p alias"])
      scope.server.run(["set-hook", "-g", "command-error", "display-message -p error-hook"])
      scope.server.open_control(session: scope.server.list_sessions.first.ref) do |control|
        reply = control.exchange("probe ; kill-session -t does-not-exist ; display-message -p never")
        assert_equal :boundary_window, reply.attribution
        refute_respond_to reply, :success?
        assert_includes reply.blocks.map(&:body).join, "alias\n"
        refute_includes reply.blocks.map(&:body).join, "never\n"
        assert reply.blocks.any? { |block| block.terminator == :error }
        fake = control.exchange("display-message -p 'parse error: unknown command: libtmux_boundary_guess'")
        assert_includes fake.blocks.map(&:body).join, "libtmux_boundary_guess"
        reply = control.exchange(%q{run-shell 'printf "outside-reply\n"; exit 17'})
        refute_includes reply.blocks.map(&:body).join, "outside-reply"
        events = []
        loop do
          event = control.events.next(timeout: 0.5)
          events << event.raw
          break if event.raw.include?("returned 17")
        end
        assert_includes events.join, "outside-reply"
        failure = assert_raises(LibTmux::ProtocolError) { control.exchange(%q{run-shell 'printf "%%end 1 1 1\n"'}) }
        assert_equal :possibly_sent, failure.delivery
        assert_raises(LibTmux::ClosedError) { control.exchange("display-message -p closed") }
      end
    end
  end

  def test_control_pipeline_preserves_reply_ownership_and_cancel_delivery
    [false, true].each do |cancel_first|
      with_scope do |scope, parent|
        control = scope.server.open_control(session: scope.server.list_sessions.first.ref)
        token = LibTmux::Internal::Cancellation.new
        reader, writer = IO.pipe
        sent = +"".b
        input = control.instance_variable_get(:@driver).instance_variable_get(:@writer)
        input.define_singleton_method(:write_nonblock) do |bytes, **options|
          result = super(bytes.byteslice(0, 7), **options)
          if result.is_a?(Integer)
            sent << bytes.byteslice(0, result)
            writer.write_nonblock("x") if /pipeline-second\nlibtmux_boundary_[0-9a-f]+\n\z/.match?(sent)
          end
          result
        end
        first = parent.async do
          control.exchange("wait-for -S pipeline-ready ; wait-for pipeline-held ; display-message -p pipeline-first", timeout: 0.5, cancel: token)
        rescue LibTmux::Error => error
          error
        end
        assert scope.server.run(["wait-for", "pipeline-ready"]).success?
        second = parent.async do
          control.exchange("display-message -p pipeline-second", timeout: 0.5)
        rescue LibTmux::Error => error
          error
        end
        assert Fiber.scheduler.io_wait(reader, IO::READABLE, 0.2), "second request bytes waited for the first reply"
        refute first.finished?
        refute second.finished?
        if cancel_first
          token.cancel
          failure, later = first.wait, second.wait
          assert_instance_of LibTmux::Cancelled, failure
          assert_instance_of LibTmux::ClosedError, later
          assert_equal [:possibly_sent, :possibly_sent], [failure.delivery, later.delivery]
        else
          assert scope.server.run(["wait-for", "-S", "pipeline-held"]).success?
          assert_equal "pipeline-first\n", first.wait.blocks.map(&:body).join
          assert_equal "pipeline-second\n", second.wait.blocks.map(&:body).join
        end
        control.close
        assert_empty control.instance_variable_get(:@requests)
        assert_empty control.instance_variable_get(:@replies)
        assert_raises(Errno::ECHILD) { Process.waitpid(control.pid, Process::WNOHANG) }
      ensure
        control&.close
        [first, second].compact.each(&:wait)
        input&.singleton_class&.remove_method(:write_nonblock)
        [reader, writer].compact.each(&:close)
        token&.close
      end
    end
  end

  def test_control_overflow_and_tail_gaps_do_not_block_replies
    with_scope do |scope, parent|
      scope.server.open_control(session: scope.server.list_sessions.first.ref) do |control|
        reliable = control.subscribe(max_events: 1, max_bytes: 1024)
        tail = control.subscribe(mode: :tail, max_events: 1, max_bytes: 1024)
        3.times { |index| scope.server.run(["rename-window", "-t", "@0", "async-window#{index}"]) }
        assert_equal "alive\n", control.exchange("display-message -p alive").blocks.last.body
        assert_instance_of LibTmux::ControlEvent, reliable.next(timeout: 0.5)
        assert_raises(LibTmux::SubscriptionOverflow) { reliable.next(timeout: 0.5) }
        gap = tail.next(timeout: 0.5)
        assert_equal :gap, gap.kind
        assert_operator gap.dropped_bytes, :>, 0
        assert_instance_of LibTmux::ControlEvent, tail.next(timeout: 0.5)
        failure = Thread.new { control.exchange("display-message -p wrong") rescue $! }.value
        assert_instance_of LibTmux::ClosedError, failure
      end
    end
  end

  def test_control_dispatched_cancellation_retires_connection_and_owned_watchers
    with_scope do |scope, parent|
      control = scope.server.open_control(session: scope.server.list_sessions.first.ref, max_requests: 1)
      token = LibTmux::Internal::Cancellation.new
      request = parent.async do
        control.exchange("wait-for -S async-abort-ready ; wait-for async-abort-held", cancel: token)
      rescue LibTmux::Cancelled => failure
        failure
      end
      assert scope.server.run(["wait-for", "async-abort-ready"]).success?
      assert_raises(LibTmux::CapacityError) { control.exchange("display-message -p excess") }
      token.cancel
      failure = request.wait
      assert_instance_of LibTmux::Cancelled, failure
      assert_equal :possibly_sent, failure.delivery
      control.close
      assert_raises(Errno::ECHILD) { Process.waitpid(control.pid, Process::WNOHANG) }
      assert scope.server.run(["has-session", "-t", "$0"]).success?
    ensure
      token&.close
    end
  end

  def test_scope_close_joins_control_exchange_cleanup_before_returning
    with_scope do |scope, parent|
      control = scope.server.open_control(session: scope.server.list_sessions.first.ref)
      token = LibTmux::Internal::Cancellation.new
      entered, release = Queue.new, Queue.new
      request = nil
      selected = false
      trace = TracePoint.new(:call) do |event|
        if event.defined_class == ::Async::Task && event.method_id == :cancel &&
            ::Async::Task.current?.equal?(request) && !selected
          selected = true
          entered << true
          release.pop
        end
      end
      trace.enable
      request = parent.async { control.exchange("display-message -p complete", cancel: token) }
      entered.pop
      closer = parent.async { scope.close }
      control.instance_variable_get(:@worker).wait
      parent.yield
      refute closer.finished?, "scope close returned while an exchange still owned completion pipes and a watcher"
      release << true
      closer.wait
      assert_equal "complete\n", request.wait.blocks.last.body
      assert_empty control.instance_variable_get(:@request_pipes)
    ensure
      trace&.disable
      release << true if release
      request&.wait
      closer&.wait
      token&.close
    end
  end

  def test_async_drain_deadline_bounds_an_externally_retained_pipe
    with_scope(drain_timeout: 0.03) do |scope, parent, fixture|
      listener = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "async-retained"))
      code = 'require "socket"; UNIXSocket.open(ARGV.fetch(0)) { |io| io.send_io(STDOUT) }; STDOUT.write("prefix")'
      request = parent.async do
        scope.__send__(:execute, ruby(code) + [listener.path])
      rescue LibTmux::DeadlineExceeded => failure
        failure
      end
      peer = listener.accept
      held = peer.recv_io
      assert scope.server.run(["has-session", "-t", "$0"]).success?
      failure = request.wait
      assert_instance_of LibTmux::DeadlineExceeded, failure
      assert_equal :observed, failure.delivery
      assert_equal :drain, failure.phase
      assert_raises(Errno::ECHILD) { Process.waitpid(failure.pid, Process::WNOHANG) }
    ensure
      held&.close
      peer&.close
      listener&.close
    end
  end

  def test_async_observer_failure_retains_and_reaps_its_real_child
    with_scope(cleanup_timeout: 0.08) do |scope, parent, fixture|
      listener = UNIXServer.new(File.join(File.dirname(fixture.socket_path), "async-observer"))
      release = Queue.new
      trace = TracePoint.new(:call) do |event|
        if event.defined_class == LibTmux::Internal::ProcessWait && event.method_id == :observe
          release.pop
          raise IOError, "observer failure"
        end
      end
      trace.enable
      code = 'require "socket"; UNIXSocket.open(ARGV.fetch(0)) { |io| io.write(Process.pid.to_s + "\\n"); io.read(1) }'
      request = parent.async do
        scope.__send__(:execute, ruby(code) + [listener.path])
      rescue LibTmux::TransportError => failure
        failure
      end
      peer = listener.accept
      pid = Integer(peer.gets, 10)
      trace.disable
      release << true
      failure = request.wait
      assert_instance_of LibTmux::TransportError, failure
      assert failure.cleanup_errors.any? { |entry| entry.include?("observation") }
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    ensure
      trace&.disable
      release << true if release
      peer&.close
      listener&.close
    end
  end

  def test_control_spawn_failure_is_reported_without_losing_admission
    with_scope do |scope, parent, fixture|
      executable = File.join(File.dirname(fixture.socket_path), "removed-async-client")
      File.write(executable, "#!/bin/sh\nexit 1\n")
      File.chmod(0o700, executable)
      LibTmux::Server.open(socket_path: fixture.socket_path, executable: executable) do |source|
        ref = source.__send__(:build_entity, :session, "$0").ref
        File.unlink(executable)
        LibTmux::Async.open(parent: parent, server: source, max_controls: 1) do |isolated|
          before = Dir.children("/dev/fd").length
          resources = lambda do
            Dir.children("/dev/fd").filter_map do |fd|
              target = File.readlink("/dev/fd/#{fd}") rescue nil
              [fd, target] if target&.match?(/\A(?:pipe|socket|anon_inode):/)
            end
          end
          before_resources = resources.call
          trace = TracePoint.new(:call) do |event|
            if event.method_id == :spawn && event.self.class.name.end_with?("::ControlDriver")
              ::Async::Task.current.yield
            end
          end
          trace.enable do
            2.times do
              failure = assert_raises(LibTmux::TransportError) { isolated.server.open_control(session: ref) }
              assert_equal :not_sent, failure.delivery
              refute_includes failure.message, executable
            end
          end
          assert_equal before, Dir.children("/dev/fd").length, (resources.call - before_resources).inspect
        end
      end
    end
  end

  def test_control_flow_and_explicit_reconnect_report_loss_on_the_owning_scope
    with_scope(max_controls: 2) do |scope, parent|
      session = scope.server.list_sessions.first.ref
      control = scope.server.open_control(session: session)
      observer = scope.server.open_control(session: session)
      stream = control.subscribe(pane_id: "%0")
      witness = observer.subscribe(pane_id: "%0")
      observer.exchange("display-message -p observer-ready", timeout: 0.5)
      assert_instance_of LibTmux::GuardedReply, control.pause_output(pane_id: "%0", timeout: 0.5)
      pause = stream.next(timeout: 0.5)
      assert_includes [:pause, :pause_requested], pause.reason
      assert_nil pause.dropped_bytes
      scope.server.run(["send-keys", "-t", "%0", "-l", "async-missed\n"])
      loop { break if witness.next(timeout: 0.5).data&.include?("async-missed") }
      control.resume_output(pane_id: "%0", timeout: 0.5)
      resume = stream.next(timeout: 0.5)
      assert_includes [:resume, :resume_requested], resume.reason
      scope.server.run(["send-keys", "-t", "%0", "-l", "async-resumed\n"])
      observed = +"".b
      loop do
        event = stream.next(timeout: 0.5)
        assert_equal :output, event.kind
        observed << event.data
        break if observed.include?("async-resumed")
      end
      refute_includes observed, "async-missed"
      control.close
      fresh = scope.server.open_control(session: session, reconnect: control)
      gap = fresh.events.next(timeout: 0.5)
      assert_equal :reconnect, gap.reason
      assert_equal control.generation, gap.previous_generation
      refute_equal control.generation, gap.generation
      assert_equal fresh.generation, fresh.events.generation
      assert_nil gap.dropped_bytes
      fresh.exchange("display-message -p renewed", timeout: 0.5)
      fresh.close
      observer.close
      [control, fresh, observer].each do |connection|
        assert_raises(Errno::ECHILD) { Process.waitpid(connection.pid, Process::WNOHANG) }
      end
    end
  end

  private

  def with_scope(**options)
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |source|
        Async do |parent|
          parent.with_timeout(0.8) do
            LibTmux::Async.open(parent: parent, server: source, **options) { |scope| yield scope, parent, fixture }
          end
        end.wait
      end
    end
  end

  def ruby(code)
    [Gem.ruby, "--disable=rubyopt,gems", "-e", code]
  end
end
