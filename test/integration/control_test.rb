# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require_relative "../support/control_assertions"
require "libtmux/control"
require "libtmux/process"

class ControlIntegrationTest < Minitest::Test
  include LibTmuxTest::ControlAssertions
  def with_control(**options)
    LibTmuxTest::TmuxFixture.open do |fixture|
      pin = LibTmux::Internal::SocketIdentity.new(LibTmux::Endpoint.new(socket_path: fixture.socket_path))
      begin
        LibTmux::ControlConnection.open(binding: pin, session_id: "$0", **options) do |connection|
          yield fixture, pin, connection
        end
      ensure
        pin.close
      end
    end
  end

  def test_boundaries_preserve_groups_aliases_hooks_and_protocol_looking_payload
    with_control do |fixture, _, control|
      fixture.tmux("set-option", "-s", "command-alias[99]", "probe=display-message -p alias")
      fixture.tmux("set-hook", "-g", "command-error", "display-message -p error-hook")
      reply = control.exchange("probe ; kill-session -t does-not-exist ; display-message -p never", timeout: 0.5)
      assert_instance_of LibTmux::GuardedReply, reply
      assert_equal :boundary_window, reply.attribution
      refute_respond_to reply, :success?
      body = reply.blocks.map(&:body).join
      assert_includes body, "alias\n"
      refute_includes body, "never\n"
      assert reply.blocks.any? { |block| block.terminator == :error }
      fake = control.exchange("display-message -p 'parse error: unknown command: libtmux_boundary_guess'", timeout: 0.5)
      assert_includes fake.blocks.map(&:body).join, "libtmux_boundary_guess"
      assert_equal "ok\n", control.exchange("display-message -p ok", timeout: 0.5).blocks.last.body
    end
  end

  def test_native_pause_and_resume_preserve_prefix_and_report_unknown_loss
    with_control do |fixture, pin, control|
      LibTmux::ControlConnection.open(binding: pin, session_id: "$0") do |observer|
        stream = control.subscribe(pane_id: "%0")
        witness = observer.subscribe(pane_id: "%0")
        observer.exchange("display-message -p observer-ready", timeout: 0.5)
        fixture.tmux("send-keys", "-t", "%0", "-l", "prefix-marker\n")
        loop { break if witness.next(timeout: 0.5).data&.include?("prefix-marker") }

        assert_instance_of LibTmux::GuardedReply, control.pause_output(pane_id: "%0", timeout: 0.5)
        prefix = []
        loop do
          event = stream.next(timeout: 0.5)
          prefix << event
          break if event.kind == :gap
        end
        assert_includes prefix.filter_map(&:data).join, "prefix-marker"
        assert_includes [:pause, :pause_requested], prefix.last.reason
        assert_nil prefix.last.dropped_bytes

        fixture.tmux("send-keys", "-t", "%0", "-l", "missed-marker\n")
        loop { break if witness.next(timeout: 0.5).data&.include?("missed-marker") }
        reply = control.resume_output(pane_id: "%0", timeout: 0.5)
        refute_respond_to reply, :success?
        resumed = stream.next(timeout: 0.5)
        assert_includes [:resume, :resume_requested], resumed.reason
        assert_equal "%0", resumed.pane_id
        assert_nil resumed.dropped_bytes
        fixture.tmux("send-keys", "-t", "%0", "-l", "resumed-marker\n")
        output = +"".b
        loop do
          event = stream.next(timeout: 0.5)
          assert_equal :output, event.kind
          output << event.data
          break if output.include?("resumed-marker")
        end
        refute_includes output, "missed-marker"
        assert_equal control.generation, stream.generation
        assert_raises(ArgumentError) { control.pause_output(pane_id: "%0; kill-server") }
      ensure
        stream&.close
        witness&.close
      end
    end
  end

  def test_explicit_reconnect_has_a_new_generation_and_gap_without_replay
    with_control do |fixture, pin, control|
      assert_raises(ArgumentError) do
        LibTmux::ControlConnection.new(binding: pin, session_id: "$0", reconnect: control)
      end
      control.exchange("new-window -d -n once", timeout: 0.5)
      old_generation, old_pid = control.generation, control.pid
      control.close
      assert_raises(Errno::ECHILD) { Process.waitpid(old_pid, Process::WNOHANG) }
      LibTmux::ControlConnection.open(binding: pin, session_id: "$0", reconnect: control) do |fresh|
        refute_equal old_generation, fresh.generation
        assert_equal old_generation, fresh.previous_generation
        [fresh.events, fresh.subscribe(pane_id: "%0")].each do |stream|
          gap = stream.next(timeout: 0.5)
          assert_equal :gap, gap.kind
          assert_equal :reconnect, gap.reason
          assert_equal old_generation, gap.previous_generation
          assert_equal fresh.generation, gap.generation
          assert_equal fresh.generation, stream.generation
          assert_nil gap.dropped_bytes
          assert_nil gap.lost_sequences
        end
        reply = fresh.exchange(%q{list-windows -F '#{window_name}'}, timeout: 0.5)
        assert_equal 1, reply.blocks.flat_map { |block| block.body.lines }.count("once\n")
      end
      other = LibTmux::Internal::SocketIdentity.new(LibTmux::Endpoint.new(socket_path: fixture.socket_path))
      assert_raises(ArgumentError) do
        LibTmux::ControlConnection.new(binding: other, session_id: "$0", reconnect: control)
      end
    ensure
      other&.close
    end
  end

  def test_cancelled_flow_request_reports_uncertain_loss_only_after_dispatch
    with_control do |fixture, _, control|
      token = LibTmux::Internal::Cancellation.new
      stream = control.subscribe(pane_id: "%0")
      token.cancel
      error = assert_raises(LibTmux::Cancelled) { control.pause_output(pane_id: "%0", cancel: token) }
      assert_equal :not_sent, error.delivery
      assert_raises(LibTmux::DeadlineExceeded) { stream.next(timeout: 0) }
      token.close
      token = LibTmux::Internal::Cancellation.new
      fixture.tmux("set-option", "-s", "command-alias[99]",
        "refresh-client=wait-for -S flow-started ; wait-for flow-held ; refresh")
      task = Thread.new do
        control.pause_output(pane_id: "%0", cancel: token, timeout: 0.5)
      rescue LibTmux::Cancelled => failure
        failure
      end
      fixture.tmux("wait-for", "flow-started")
      token.cancel
      assert_equal :possibly_sent, task.value.delivery
      gap = stream.next(timeout: 0.5)
      assert_equal :pause_requested, gap.reason
      assert_nil gap.dropped_bytes
      control.close
      assert_raises(Errno::ECHILD) { Process.waitpid(control.pid, Process::WNOHANG) }
    ensure
      task&.join(0.5)
      token&.close
      stream&.close
    end
  end

  def test_wait_holds_boundary_until_an_independent_client_releases_it
    with_control do |fixture, _, control|
      thread = Thread.new do
        control.exchange("wait-for -S control-started ; wait-for control-release ; display-message -p released", timeout: 0.5)
      end
      fixture.tmux("wait-for", "control-started")
      assert thread.alive?, "WAIT must keep the request boundary pending after its successful guard"
      fixture.tmux("wait-for", "-S", "control-release")
      assert_includes thread.value.blocks.map(&:body).join, "released\n"
    ensure
      thread&.join(0.5)
    end
  end

  def test_control_retains_server_binding_and_close_reaps_only_owned_client
    with_control do |fixture, pin, control|
      pid = control.pid
      pin.close
      assert_equal "retained\n", control.exchange("display-message -p retained", timeout: 0.5).blocks.last.body
      control.close
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      assert fixture.tmux("has-session", "-t", "fixture").last.success?
      assert_raises(LibTmux::ClosedError) { control.exchange("display-message -p later") }
    end
  end

  def test_pipeline_writes_complete_requests_before_prior_replies
    with_control do |fixture, _, control|
      fixture.tmux("set-option", "-s", "command-alias[99]",
        "pipeline-probe=wait-for -S pipeline-ready ; wait-for pipeline-held ; display-message -p pipeline-first ; kill-session -t missing ; display-message -p never")
      fixture.tmux("set-hook", "-g", "command-error", "display-message -p pipeline-hook")
      reader, writer = IO.pipe
      sent = +"".b
      input = control.instance_variable_get(:@input)
      input.define_singleton_method(:write_nonblock) do |bytes, **options|
        result = super(bytes.byteslice(0, 7), **options)
        if result.is_a?(Integer)
          sent << bytes.byteslice(0, result)
          writer.write_nonblock("x") if /pipeline-second\nlibtmux_boundary_[0-9a-f]+\n\z/.match?(sent)
        end
        result
      end
      first = Thread.new do
        control.exchange("pipeline-probe", timeout: 0.5)
      end
      fixture.tmux("wait-for", "pipeline-ready")
      second = Thread.new { control.exchange("display-message -p pipeline-second", timeout: 0.5) }
      assert IO.select([reader], nil, nil, 0.2), "second request bytes waited for the first reply"
      assert first.alive?, "the first reply must remain pending at the wire witness"
      assert second.alive?, "tmux must retain the second request behind WAIT"
      assert_respond_to control, :diagnostics
      pending = control.diagnostics
      assert_equal [2, 2, 2], pending.values_at(:admitted_requests, :incomplete_requests, :awaiting_reply)
      assert_equal 0, pending.fetch(:queued_requests)
      assert_operator pending.fetch(:reserved_wire_bytes), :>, 0
      assert pending.frozen?
      assert pending.fetch(:limits).frozen?
      fixture.tmux("wait-for", "-S", "pipeline-held")
      earlier = first.value
      assert_includes earlier.blocks.map(&:body).join, "pipeline-first\n"
      refute_includes earlier.blocks.map(&:body).join, "pipeline-second\n"
      refute_includes earlier.blocks.map(&:body).join, "never\n"
      assert earlier.blocks.any? { |block| block.terminator == :error }
      assert_equal "pipeline-second\n", second.value.blocks.map(&:body).join
      assert_equal [0, 0, 0, 0], control.diagnostics.values_at(:admitted_requests,
        :incomplete_requests, :reserved_wire_bytes, :retained_reply_bytes)
      assert_empty control.instance_variable_get(:@requests)
    ensure
      fixture.tmux("wait-for", "-S", "pipeline-held") if first&.alive?
      [first, second].compact.each { |thread| thread.join(0.5) }
      input&.singleton_class&.remove_method(:write_nonblock)
      [reader, writer].compact.each(&:close)
    end
  end

  def test_slow_subscriber_overflows_without_blocking_replies
    with_control do |fixture, _, control|
      events = control.subscribe(max_events: 1, max_bytes: 1024)
      3.times { |index| fixture.tmux("rename-window", "-t", "@0", "window#{index}") }
      assert_equal "alive\n", control.exchange("display-message -p alive", timeout: 0.5).blocks.last.body
      assert_instance_of LibTmux::ControlEvent, events.next(timeout: 0.5)
      assert_raises(LibTmux::SubscriptionOverflow) { events.next(timeout: 0.5) }
    end
  end

  def test_dispatched_cancellation_closes_connection_and_preserves_server
    with_control do |fixture, _, control|
      entered, release = Queue.new, Queue.new
      control.singleton_class.prepend(Module.new do
        define_method(:receive) do |record|
          if record.is_a?(LibTmux::GuardedBlock) && record.body == "cancelled-prefix\n"
            entered << true
            release.pop
          end
          super(record)
        end
      end)
      token = LibTmux::Internal::Cancellation.new
      thread = Thread.new do
        control.exchange("display-message -p cancelled-prefix ; wait-for -S cancellation-started ; wait-for blocked", timeout: 0.5, cancel: token)
      rescue LibTmux::Cancelled => error
        error
      end
      fixture.tmux("wait-for", "cancellation-started")
      entered.pop
      token.cancel
      error = thread.value
      release << true
      assert_instance_of LibTmux::Cancelled, error
      assert_equal :possibly_sent, error.delivery
      control.close
      retired = control.diagnostics
      assert retired.fetch(:stopping)
      assert retired.fetch(:finished)
      assert_equal [0, 0, 0, 0, 0, 0, 0], retired.values_at(:admitted_requests,
        :incomplete_requests, :queued_requests, :writing_requests, :awaiting_reply,
        :reserved_wire_bytes, :retained_reply_bytes)
      assert_equal 0, retired.fetch(:cleanup_error_count)
      assert fixture.tmux("has-session", "-t", "fixture").last.success?
    ensure
      release << true
      token&.close
      thread&.join(0.5)
    end
  end

  def test_outside_wait_output_is_an_event_and_corruption_fails_closed
    with_control do |fixture, _, control|
      assert_run_shell_routing(control, fixture.tmux("-V").first)
    end
  end

  def test_pending_admission_is_bounded_and_cancellation_before_admission_is_not_sent
    with_control(max_requests: 1) do |fixture, _, control|
      token = LibTmux::Internal::Cancellation.new
      token.cancel
      error = assert_raises(LibTmux::Cancelled) { control.exchange("display-message -p never", cancel: token) }
      assert_equal :not_sent, error.delivery
      thread = Thread.new do
        control.exchange("wait-for -S capacity-started ; wait-for capacity-release", timeout: 0.5)
      end
      fixture.tmux("wait-for", "capacity-started")
      assert_raises(LibTmux::CapacityError) { control.exchange("display-message -p excess") }
      fixture.tmux("wait-for", "-S", "capacity-release")
      assert_instance_of LibTmux::GuardedReply, thread.value
      assert_equal "still-open\n", control.exchange("display-message -p still-open", timeout: 0.5).blocks.last.body
    ensure
      token&.close
      thread&.join(0.5)
    end
  end

  def test_repeated_thread_cancellation_preserves_first_failure_during_retirement
    with_control do |fixture, _, control|
      cleanup_entered, cleanup_release = Queue.new, Queue.new
      control.singleton_class.prepend(Module.new do
        define_method(:abort_request) do |request, type, message|
          if message == "control request interrupted"
            cleanup_entered << true
            cleanup_release.pop
          end
          super(request, type, message)
        end
      end)
      first = Interrupt.new("first cancellation")
      thread = Thread.new do
        control.exchange("wait-for -S interrupt-started ; wait-for interrupt-blocked", timeout: 0.5)
      rescue Exception => failure
        failure
      end
      fixture.tmux("wait-for", "interrupt-started")
      thread.raise(first)
      cleanup_entered.pop
      thread.raise(Interrupt.new("second cancellation"))
      cleanup_release << true
      assert_same first, thread.value
      control.close
      assert_raises(Errno::ECHILD) { Process.waitpid(control.pid, Process::WNOHANG) }
    ensure
      cleanup_release << true
      thread&.join(0.5)
    end
  end

  def test_detach_closes_pending_request_without_waiting_for_deadline
    with_control do |_, _, control|
      control.exchange("detach-client", timeout: 0.5)
      loop { break if control.events.next(timeout: 0.5).raw.start_with?("%exit") }
      assert_raises(LibTmux::ClosedError) { control.exchange("display-message -p detached", timeout: 0.5) }
      control.close
      assert_raises(Errno::ECHILD) { Process.waitpid(control.pid, Process::WNOHANG) }
    end
  end

  def test_request_construction_failure_closes_allocated_completion_pipes
    with_control do |_, _, control|
      request_class = LibTmux::ControlConnection.const_get(:Request)
      original_new = request_class.method(:new)
      streams = nil
      request_class.define_singleton_method(:new) do |**attributes|
        streams = [attributes.fetch(:reader), attributes.fetch(:writer)]
        raise NoMemoryError, "request allocation injection"
      end
      assert_raises(NoMemoryError) { control.exchange("display-message -p unused") }
      assert streams.all?(&:closed?), "failed request admission must close both completion pipes"
    ensure
      request_class.define_singleton_method(:new, original_new)
      streams&.each { |io| io.close unless io.closed? }
    end
  end

  def test_forked_child_rejects_inherited_streams_and_detaches_all_local_pipes
    with_control do |_, _, control|
      stream = control.subscribe
      reader, writer = IO.pipe
      child = fork do
        reader.close
        rejected = begin
          stream.next(timeout: 0)
          false
        rescue LibTmux::ClosedError
          true
        rescue LibTmux::DeadlineExceeded
          false
        end
        control.close
        writer.write(rejected ? "closed" : "wrong")
        writer.close
        exit! 0
      end
      writer.close
      assert IO.select([reader], nil, nil, 0.5), "fork check must report through its pipe"
      assert_equal "closed", reader.read
      Process.wait(child)
      assert_equal "parent\n", control.exchange("display-message -p parent", timeout: 0.5).blocks.last.body
    ensure
      [reader, writer].compact.each { |io| io.close unless io.closed? }
      Process.wait(child) rescue Errno::ECHILD
    end
  end

  def test_failed_exit_observation_cannot_turn_cleanup_into_blocking_waitpid
    check_failed_observation
  end

  def test_late_exit_observation_failure_receives_final_retirement_token
    check_failed_observation(late: true)
  end

  def check_failed_observation(late: false)
    LibTmuxTest::TmuxFixture.open do |fixture|
      original_rubyopt = ENV["RUBYOPT"]
      executable = File.join(File.dirname(fixture.socket_path), "control-child")
      File.write(executable, "#!#{RbConfig.ruby} --disable=rubyopt,gems\ntrap('TERM') {}\nSTDOUT.write(\"ready\\n\"); STDOUT.flush\nIO.select([])\n")
      File.chmod(0o700, executable)
      ambient_startup = File.join(File.dirname(fixture.socket_path), "ambient-startup.rb")
      File.write(ambient_startup, "STDOUT.write(\"ambient startup\\n\"); STDOUT.flush\n")
      ENV["RUBYOPT"] = "-r#{ambient_startup}"
      pin = LibTmux::Internal::SocketIdentity.new(LibTmux::Endpoint.new(socket_path: fixture.socket_path, executable: executable))
      gate = Queue.new
      wait_class = LibTmux::Internal::ProcessWait
      original_new = wait_class.method(:new)
      wait_class.define_singleton_method(:new) do
        Object.new.tap do |observer|
          observer.define_singleton_method(:observe) { |_| gate.pop; raise IOError, "observer injection" }
        end
      end
      control = LibTmux::ControlConnection.open(binding: pin, session_id: "$0")
      wait_class.define_singleton_method(:new, original_new)
      assert_equal "ready\n", control.events.next(timeout: 0.5).raw
      ENV["RUBYOPT"] = original_rubyopt
      if late
        observer = control.instance_variable_get(:@child)
        observer.singleton_class.prepend(Module.new do
          define_method(:join) do |timeout|
            gate << true
            super(timeout)
          end
        end)
      else
        gate << true
      end
      error = assert_raises(LibTmux::TransportError) { control.close }
      assert error.cleanup_errors.any? { |item| item.include?("observation") }, "cleanup must report the observer failure"
      assert_raises(Errno::ECHILD) { Process.waitpid(control.pid, Process::WNOHANG) }
    ensure
      ENV["RUBYOPT"] = original_rubyopt
      wait_class&.define_singleton_method(:new, original_new) if original_new
      gate << true if gate
      if control
        control.send(:signal, "KILL")
        control.instance_variable_get(:@worker)&.join(0.5)
      end
      pin&.close
    end
  end

  def test_completed_unconsumed_requests_still_count_against_admission
    with_control(max_requests: 1) do |_, _, control|
      cleanup_entered, cleanup_release = Queue.new, Queue.new
      control.singleton_class.prepend(Module.new do
        define_method(:abort_request) do |request, type, message|
          if request.id == 1 && request.result && message == "control request interrupted"
            cleanup_entered << true
            cleanup_release.pop
          end
          super(request, type, message)
        end
      end)
      thread = Thread.new { control.exchange("display-message -p completed", timeout: 0.5) }
      cleanup_entered.pop
      assert_respond_to control, :diagnostics
      retained = control.diagnostics
      assert_equal [1, 0, 0], retained.values_at(:admitted_requests, :incomplete_requests, :awaiting_reply)
      assert_operator retained.fetch(:retained_reply_bytes), :>=, "completed\n".bytesize
      assert_raises(LibTmux::CapacityError) { control.exchange("display-message -p excess", timeout: 0.5) }
      cleanup_release << true
      reply = thread.value
      assert_equal "completed\n", reply.blocks.last.body
      assert_equal reply.blocks.sum(&:bytesize), retained.fetch(:retained_reply_bytes)
      assert_equal [0, 0], control.diagnostics.values_at(:reserved_wire_bytes, :retained_reply_bytes)
      assert_equal "next\n", control.exchange("display-message -p next", timeout: 0.5).blocks.last.body
    ensure
      cleanup_release << true
      thread&.join(0.5)
    end
  end
end
