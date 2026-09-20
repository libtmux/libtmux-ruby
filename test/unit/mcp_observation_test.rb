# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/mcp"

class MCPObservationTest < Minitest::Test
  def test_process_cursor_discovery_matches_native_backend_and_tmux_boundary
    observation = LibTmux::MCP.const_get(:Observation)
    {
      "arm64-darwin23" => "kqueue",
      "x86_64-darwin24" => "kqueue",
      "x86_64-linux" => "pidfds",
      "aarch64-linux" => "pidfds"
    }.each do |platform, backend|
      observation.const_set(:RUBY_PLATFORM, platform)
      current = observation.capabilities("3.7c")
      assert_equal "conditional", current.fetch("process_cursor"), platform
      assert_includes current.fetch("requirements").join(" "), backend
      assert_equal "conditional", observation.capabilities("3.3a").fetch("process_cursor")
      assert_equal "unsupported", observation.capabilities("3.2a").fetch("process_cursor")
      assert_equal "unsupported", observation.capabilities("unknown").fetch("process_cursor")
      observation.send(:remove_const, :RUBY_PLATFORM)
    end
    observation.const_set(:RUBY_PLATFORM, "x64-mingw32")
    assert_equal "unsupported", observation.capabilities("3.7c").fetch("process_cursor")
  ensure
    observation.send(:remove_const, :RUBY_PLATFORM) if observation&.const_defined?(:RUBY_PLATFORM, false)
  end
end
