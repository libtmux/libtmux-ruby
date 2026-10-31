# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

Dir[File.expand_path("../gems/*/lib", __dir__)].sort.reverse_each do |path|
  $LOAD_PATH.unshift(path)
end

module LibTmuxTest
  # Runs before any test. The process environment names a private, owner-only
  # tmux directory and no socket, so code that reads it and reaches for the
  # default server finds that directory, never the server of whoever runs the
  # suite. Refuses to run when the directory cannot be made.
  def self.enter_private_tmux_directory
    %w[TMUX TMUX_PANE].each { |name| ENV.delete(name) }
    ENV.keys.grep(/\ALIBTMUX_SOCKET/).each { |name| ENV.delete(name) }
    directory = Dir.mktmpdir("libtmux-ruby-tmux-")
    stat = File.stat(directory)
    unless stat.directory? && stat.owned? && (stat.mode & 0o077).zero?
      FileUtils.remove_entry(directory)
      abort "test_helper: the private TMUX_TMPDIR is not an owner-only directory; refusing to run"
    end
    ENV["TMUX_TMPDIR"] = directory
    owner = Process.pid
    Minitest.after_run do
      FileUtils.remove_entry(directory) if Process.pid == owner && File.directory?(directory)
    end
    directory.freeze
  rescue SystemCallError, ArgumentError
    abort "test_helper: cannot create a private TMUX_TMPDIR; refusing to run against the default tmux server"
  end

  PRIVATE_TMUX_DIRECTORY = enter_private_tmux_directory
end
