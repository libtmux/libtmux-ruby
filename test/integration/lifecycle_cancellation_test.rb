# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"

class LifecycleCancellationTest < Minitest::Test
  %i[server session window pane].each do |kind|
    define_method("test_adoption_cancelled_after_receipt_for_#{kind}") do
      with_resource(kind) do |server, resource, fixture|
        with_cancel do |cancel|
          cancel_after_receipt(server, cancel)
          failure = assert_raises(LibTmux::Cancelled) { resource.adopt(cancel: cancel) }
          assert_equal :handoff, failure.phase
          assert_equal :observed, failure.delivery
          assert_removed(server, resource, kind, fixture)
        end
      end
    end

    define_method("test_adoption_block_skipped_after_cancelled_receipt_for_#{kind}") do
      with_resource(kind) do |server, resource, fixture|
        with_cancel do |cancel|
          cancel_after_receipt(server, cancel)
          entered = false
          assert_raises(LibTmux::Cancelled) { resource.adopt(cancel: cancel) { entered = true } }
          refute entered
          assert_removed(server, resource, kind, fixture)
        end
      end
    end

    define_method("test_pre_cancelled_adoption_preserves_borrowed_#{kind}") do
      with_resource(kind) do |server, resource, _fixture|
        with_cancel do |cancel|
          before = inventory(server)
          commands = []
          original = server.method(:run)
          server.define_singleton_method(:run) { |*args, **options| commands << args; original.call(*args, **options) }
          cancel.cancel
          assert_raises(LibTmux::Cancelled) { resource.adopt(cancel: cancel) }
          assert_empty commands
          assert_equal before, inventory(server)
        end
      end
    end
  end

  %i[session window pane].each do |kind|
    define_method("test_pre_cancelled_reuse_preserves_borrowed_#{kind}") do
      with_reused_resource(kind) do |server, find|
        with_cancel do |cancel|
          before = inventory(server)
          cancel.cancel
          assert_raises(LibTmux::Cancelled) { find.call(cancel) }
          assert_equal before, inventory(server)
        end
      end
    end

    define_method("test_reuse_cancellation_after_list_command_for_#{kind}") do
      with_reused_resource(kind) do |server, find|
        with_cancel do |cancel|
          before = inventory(server)
          original = server.method(:run)
          server.define_singleton_method(:run) do |arguments, **options|
            original.call(arguments, **options).tap { cancel.cancel if arguments.first.start_with?("list-") }
          end
          assert_raises(LibTmux::Cancelled) { find.call(cancel) }
          assert_equal before, inventory(server)
        end
      end
    end

    define_method("test_reuse_cancellation_at_value_handoff_for_#{kind}") do
      with_reused_resource(kind) do |server, find|
        with_cancel do |cancel|
          before = inventory(server)
          original = server.method(:lifecycle_value)
          expected = {session: "cancel-target", window: "cancel-window", pane: "cancel-pane"}.fetch(kind).b
          server.define_singleton_method(:lifecycle_value) do |*args, **options|
            original.call(*args, **options).tap { |value| cancel.cancel if value == expected }
          end
          assert_raises(LibTmux::Cancelled) { find.call(cancel) }
          assert_equal before, inventory(server)
        end
      end
    end
  end

  def test_adoption_cancellation_and_failed_rollback_retain_recovery_owner
    with_resource(:window) do |server, resource, _fixture|
      with_cancel do |cancel|
        cancel_after_receipt(server, cancel)
        cleanup = IOError.new("adoption rollback failed").freeze
        original_destroy = server.method(:destroy_owned)
        server.define_singleton_method(:destroy_owned) { |*, **| raise cleanup }
        original_rollback = server.method(:rollback_owner)
        accepted_failure = nil
        server.define_singleton_method(:rollback_owner) do |owner, failure|
          accepted_failure = failure
          original_rollback.call(owner, failure)
        end
        failure = assert_raises(LibTmux::CleanupError) { resource.adopt(cancel: cancel) }
        assert_instance_of LibTmux::Cancelled, failure.body_error
        assert_same accepted_failure, failure.body_error
        assert_same cleanup, failure.cleanup_error
        assert_same resource, failure.recovery.resource
        refute failure.recovery.closed?
        assert_includes server.list_windows.map(&:id), resource.id
        server.define_singleton_method(:destroy_owned, original_destroy)
        failure.recovery.close
        assert failure.recovery.closed?
        refute_includes server.list_windows.map(&:id), resource.id
      end
    end
  end

  def test_cancelled_waiter_leaves_gate_without_waiting_for_holder
    with_reused_resource(:session) do |server, find|
      with_cancel do |cancel|
        before = inventory(server)
        gate = LibTmux::Internal.const_get(:LifecycleGate, false)
        held, release, waiting = Queue.new, Queue.new, Queue.new
        condition = gate.instance_variable_get(:@condition)
        original_wait = condition.method(:wait)
        condition.define_singleton_method(:wait) do |*args|
          waiting << true
          original_wait.call(*args)
        end
        holder = Thread.new { gate.synchronize(timeout: 5.0) { held << true; release.pop } }
        held.pop
        waiter = Thread.new do
          assert_raises(LibTmux::Cancelled) { find.call(cancel) }
        end
        waiting.pop
        cancel.cancel
        assert waiter.join(1.0), "cancelled waiter remained behind the gate holder"
        assert_equal before, inventory(server)
      ensure
        release << true if holder
        holder&.join
        waiter&.join
        condition&.define_singleton_method(:wait, original_wait)
      end
    end
  end

  def test_pane_identity_handoff_cancellation_rolls_back_created_pane
    with_resource(:window) do |server, window, _fixture|
      with_cancel do |cancel|
        before = window.list_panes.map(&:id)
        original = server.method(:lifecycle_value)
        server.define_singleton_method(:lifecycle_value) do |entity, *args, **options|
          original.call(entity, *args, **options).tap { cancel.cancel unless before.include?(entity.id) }
        end
        assert_raises(LibTmux::Cancelled) do
          window.find_or_create_pane(identity: "new-identity", direction: :horizontal, command: ["cat"], cancel: cancel)
        end
        assert_equal before, window.list_panes.map(&:id)
      end
    end
  end

  def test_find_or_create_keeps_positive_timeout_validation
    with_reused_resource(:session) do |server, _find|
      before = inventory(server)
      [0, -1, Float::INFINITY, Float::NAN].each do |timeout|
        assert_raises(ArgumentError) do
          server.find_or_create_session(name: "cancel-target", command: ["cat"], timeout: timeout)
        end
      end
      assert_equal before, inventory(server)
    end
  end

  private

  def with_cancel
    cancel = LibTmux::Cancellation.new
    yield cancel
  ensure
    cancel&.close
  end

  def with_resource(kind)
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        resource = if kind == :server
          server
        else
          session = server.new_session(name: "cancel-target", window_name: "cancel-window", command: ["cat"])
          window = session.list_windows.first
          {session: session, window: window, pane: window.list_panes.first}.fetch(kind)
        end
        yield server, resource, fixture
      end
    end
  end

  def with_reused_resource(kind)
    with_resource(kind) do |server, resource, _fixture|
      find = case kind
      when :session
        ->(cancel) { server.find_or_create_session(name: "cancel-target", command: ["cat"], cancel: cancel) }
      when :window
        session = server.list_sessions.find { |entry| entry.id != "$0" }
        ->(cancel) { session.find_or_create_window(name: "cancel-window", command: ["cat"], cancel: cancel) }
      when :pane
        resource.options.set("@libtmux_pane_identity", "cancel-pane")
        window = server.list_windows.find { |entry| entry.id != "@0" }
        ->(cancel) { window.find_or_create_pane(identity: "cancel-pane", direction: :horizontal, command: ["cat"], cancel: cancel) }
      end
      yield server, find
    end
  end

  def cancel_after_receipt(server, cancel)
    original = server.method(:lifecycle_execute)
    server.define_singleton_method(:lifecycle_execute) do |*args|
      original.call(*args).tap { cancel.cancel }
    end
  end

  def inventory(server)
    [server.list_sessions, server.list_windows, server.list_panes].map { |resources| resources.map(&:id) }
  end

  def assert_removed(server, resource, kind, fixture)
    if kind == :server
      assert fixture.instance_variable_get(:@server).last.wait_observed(0.5)
    else
      refute_includes server.public_send("list_#{kind}s").map(&:id), resource.id
      assert_includes server.list_sessions.map(&:id), "$0"
    end
  end
end
