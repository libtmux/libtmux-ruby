# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module LibTmuxTest
  # A tmux command that names no socket goes to the server an inherited TMUX
  # names, and otherwise to the default socket under TMUX_TMPDIR. Requiring
  # this file removes what selects a server, points TMUX_TMPDIR at a directory
  # of this run's own, and exits if either did not hold. A process started by
  # one that has entered joins its sandbox instead of making another.
  module Sandbox
    class Refused < StandardError; end

    MARKER = "LIBTMUX_TEST_SANDBOX"
    PREFIX = "lt-rb-"
    NAMES = %w[TMUX TMUX_PANE LIBTMUX_SOCKET LIBTMUX_SOCKET_PATH].freeze
    # A socket path must fit sun_path, 104 bytes on macOS. The directory leaves
    # room for /tmux-<uid>/<name>.
    MAX_BYTES = 60
    # What Dir.mktmpdir appends to PREFIX, with the separator.
    NAME_BYTES = 32

    class << self
      def ambient?(name)
        NAMES.include?(name) || name.start_with?("LIBTMUX_SOCKET")
      end

      # Findings name variables, never values: a TMUX value names a server.
      def violations(env = ENV)
        found = env.keys.select { |name| ambient?(name) && !env[name].nil? }.sort.map { |name| "#{name} is set" }
        problem = directory_problem(env)
        found << problem if problem
        found
      end

      def check!(env = ENV)
        found = violations(env)
        raise Refused, found.join("; ") unless found.empty?
      end

      # Mutates env into a sandbox and returns [directory, created].
      def prepare(env, roots: [Dir.tmpdir, "/tmp"])
        joined = directory_problem(env).nil?
        env.keys.each { |name| env.delete(name) if ambient?(name) }
        directory = joined ? env.fetch("TMUX_TMPDIR") : create(roots)
        env["TMUX_TMPDIR"] = env[MARKER] = directory
        begin
          check!(env)
        rescue Refused
          remove(directory) unless joined
          raise
        end
        [directory, !joined]
      end

      def enter!
        directory, created = prepare(ENV)
        clean_up_after(directory) if created
        directory
      end

      # The overlay for a child environment built from a saved copy of this
      # one, which would otherwise carry the variables this process removed.
      def overlay(env = ENV)
        names = (NAMES + env.keys).select { |name| ambient?(name) }.uniq
        names.to_h { |name| [name, nil] }.merge("TMUX_TMPDIR" => ENV.fetch("TMUX_TMPDIR"), MARKER => ENV.fetch(MARKER))
      end

      # Anything under tmux-<uid> is a socket tmux chose for a command that
      # named none: every test here addresses its server with -S.
      def leaks(directory)
        Dir.glob("tmux-*/*", base: directory).sort
      end

      # Stops a server a test started on the sandbox's own sockets, removes the
      # directory, and returns the relative paths of those sockets.
      def release(directory)
        found = leaks(directory)
        found.each { |path| stop(File.join(directory, path)) }
        remove(directory)
        found
      end

      private

      def directory_problem(env)
        directory = env["TMUX_TMPDIR"]
        return "TMUX_TMPDIR is unset" if directory.nil? || directory.empty?
        return "TMUX_TMPDIR is not an absolute path" unless directory.start_with?("/")
        return "TMUX_TMPDIR is longer than #{MAX_BYTES} bytes" if directory.bytesize > MAX_BYTES
        unless env[MARKER] == directory && File.basename(directory).start_with?(PREFIX)
          return "TMUX_TMPDIR is not the sandbox directory of this run"
        end
        return if File.directory?(directory) && File.stat(directory).uid == Process.euid

        "the sandbox directory is missing or belongs to another user"
      end

      def create(roots)
        root = roots.find do |path|
          path.bytesize + NAME_BYTES <= MAX_BYTES && File.directory?(path) && File.writable?(path)
        end
        raise Refused, "no temporary directory is short enough for a tmux socket path; set TMPDIR to a shorter one" unless root

        Dir.mktmpdir(PREFIX, root)
      end

      def remove(directory)
        FileUtils.rm_rf(directory) if File.basename(directory).start_with?(PREFIX)
      end

      def stop(socket)
        return unless File.socket?(socket)

        system({"TMUX" => nil, "TMUX_PANE" => nil}, ENV.fetch("LIBTMUX_TEST_TMUX", "tmux"), "-S", socket, "kill-server",
          out: File::NULL, err: File::NULL)
      rescue SystemCallError
        nil
      end

      # Minitest runs its tests inside its own exit handler, so a handler
      # registered after it would run first and remove the directory early.
      def clean_up_after(directory)
        owner = Process.pid
        cleanup = lambda do
          next unless Process.pid == owner

          found = release(directory)
          next if found.empty?

          warn "libtmux-ruby tests started tmux without -S; it chose #{found.join(', ')} in the sandbox"
          exit 1
        end
        if defined?(Minitest) && Minitest.respond_to?(:after_run)
          Minitest.after_run(&cleanup)
        else
          at_exit(&cleanup)
        end
      end
    end
  end
end

begin
  LibTmuxTest::Sandbox.enter!
rescue LibTmuxTest::Sandbox::Refused => error
  warn "libtmux-ruby tests refused to run: #{error.message}"
  exit 2
end
