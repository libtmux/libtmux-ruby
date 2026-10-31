# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/endpoint"
require "open3"

# The helper has already run when these do; they show what it left behind.
# Failures name variables and say yes or no, never the values.
class PrivateTmuxDirectoryTest < Minitest::Test
  def test_no_variable_that_names_a_server_survives
    names = ENV.keys.select { |name| %w[TMUX TMUX_PANE].include?(name) || name.start_with?("LIBTMUX_SOCKET") }
    assert_empty names, "variables that name a server are still set"
  end

  def test_tmux_tmpdir_is_an_owner_only_directory_the_helper_made
    directory = ENV["TMUX_TMPDIR"]
    assert directory == LibTmuxTest::PRIVATE_TMUX_DIRECTORY, "TMUX_TMPDIR is not the helper's directory"
    stat = File.stat(directory)
    assert stat.directory?, "the helper's directory is not a directory"
    assert stat.owned?, "the helper's directory is not owned by this user"
    assert_equal 0, stat.mode & 0o077, "the helper's directory is open to group or others"
  end

  def test_the_helper_refuses_to_run_when_it_cannot_make_the_directory
    helper = File.expand_path("../test_helper.rb", __dir__)
    code = 'require "tmpdir"; Dir.define_singleton_method(:mktmpdir) { |*| raise Errno::EACCES }; require ARGV.fetch(0)'
    output, status = Open3.capture2e(Gem.ruby, "-e", code, helper)
    refute status.success?, "the helper ran without a private directory"
    assert_includes output, "refusing to run"
  end

  def test_a_bare_endpoint_resolves_under_the_private_directory
    expected = File.join(File.expand_path(LibTmuxTest::PRIVATE_TMUX_DIRECTORY), "tmux-#{Process.uid}", "default")
    assert LibTmux::Endpoint.new.socket_path == expected, "a bare Endpoint resolves outside the private directory"
    assert LibTmux::Endpoint.from_env.socket_path == expected, "Endpoint.from_env resolves outside the private directory"
  end
end
