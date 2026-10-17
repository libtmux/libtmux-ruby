# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"

class SupportTest < Minitest::Test
  def test_the_minimum_is_shared_by_the_version_check
    assert_equal "3.3a", LibTmux::Support::MINIMUM
    assert_equal LibTmux::Support::Versions::MINIMUM, LibTmux::Support::MINIMUM
  end

  def test_require_supported_returns_the_release_text_or_refuses
    assert_equal "3.8", LibTmux::Support.require_supported("3.8")
    error = assert_raises(LibTmux::UnsupportedFeatureError) { LibTmux::Support::Versions.require_supported("3.3") }
    assert_equal :not_sent, error.delivery
    assert_match(/3\.3a or newer/, error.message)
  end

  def test_server_version_reports_the_daemons_release
    server = Struct.new(:tmux_version).new("3.7d")
    assert_equal "3.7d", LibTmux::Support.server_version(server)
    assert_equal "3.7d", LibTmux::Support::Versions.server_version(server)
  end
end
