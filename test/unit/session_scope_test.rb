# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"

class SessionScopeTest < Minitest::Test
  def test_server_block_retains_body_and_close_exceptions
    body = RuntimeError.new("body witness")
    cleanup = IOError.new("close witness")
    type = Class.new(LibTmux::Server) do
      define_method(:initialize) { |**| nil }
      define_method(:close) { raise cleanup }
    end
    failure = assert_raises(LibTmux::CleanupError) { type.open { raise body } }
    assert_equal :possibly_sent, failure.delivery
    assert_same body, failure.body_error
    assert_same cleanup, failure.cleanup_error
    refute_includes failure.cleanup_errors.join, "close witness"
  end

  def test_session_scope_requires_a_block_before_creating_a_session
    server = LibTmux::Server.allocate
    assert_raises(ArgumentError) { server.with_session(name: "unused", command: ["/bin/cat"]) }
  end
end
