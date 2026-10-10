# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux/async"

class LifecycleAsyncTest < Minitest::Test
  def test_async_body_cancellation_leaves_no_owned_session
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |source|
        Async do |parent|
          LibTmux::Async.open(parent: parent, server: source) do |scope|
            ready = ::Async::Notification.new
            child = parent.async do
              scope.server.owned_session(name: "async-cancel", command: ["cat"]) do
                ready.signal
                ::Async::Notification.new.wait
              end
            end
            ready.wait
            child.cancel
            child.wait
            assert_equal ["$0"], source.list_sessions.map(&:id)
          end
        end.wait
      end
    end
  end

  def test_async_receipt_handoff_cancellation_rolls_back
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |source|
        Async do |parent|
          LibTmux::Async.open(parent: parent, server: source) do |scope|
            original = scope.server.method(:owner_from_output)
            scope.server.define_singleton_method(:owner_from_output) do |*arguments|
              original.call(*arguments).tap { ::Async::Task.current.cancel }
            end
            child = parent.async { scope.server.owned_session(name: "async-handoff", command: ["cat"]) }
            child.wait
            assert_equal ["$0"], source.list_sessions.map(&:id)
          end
        end.wait
      end
    end
  end

  def test_async_scope_retains_body_and_cleanup_error_objects
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |source|
        Async do |parent|
          LibTmux::Async.open(parent: parent, server: source) do |scope|
            owner = scope.server.owned_session(name: "async-errors", command: ["cat"])
            original = source.method(:destroy_owned)
            body = RuntimeError.new("body")
            cleanup = IOError.new("cleanup")
            source.define_singleton_method(:destroy_owned) { |*, **| raise cleanup }
            failure = assert_raises(LibTmux::CleanupError) { owner.use { raise body } }
            assert_same body, failure.body_error
            assert_same cleanup, failure.cleanup_error
            source.define_singleton_method(:destroy_owned, original)
            failure.recovery.close
            assert_equal ["$0"], source.list_sessions.map(&:id)
          end
        end.wait
      end
    end
  end
end
