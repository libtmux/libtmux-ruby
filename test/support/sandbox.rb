# frozen_string_literal: true

require "fileutils"
require "socket"
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
    # How long kill-server may take before a socket that still accepts a
    # connection counts as a server that was not stopped.
    STOP_SECONDS = 3

    # leaked: every socket found under the sandbox, relative to it.
    # answering: those that still accepted a connection after the stop.
    Release = Struct.new(:leaked, :answering) do
      def clean?
        leaked.empty?
      end

      def message(directory)
        text = "libtmux-ruby tests left sockets in the sandbox: #{leaked.join(', ')}"
        return text if answering.empty?

        "#{text}; a server still answers at #{answering.join(', ')}, so #{File.basename(directory)} was kept"
      end
    end

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

      # Every variable that selects a server, set to nil, for the child
      # environment of a command that starts tmux with its own TMUX_TMPDIR.
      def scrub(env = ENV)
        (NAMES + env.keys).select { |name| ambient?(name) }.uniq.to_h { |name| [name, nil] }
      end

      # The overlay for a child environment built from a saved copy of this
      # one, which would otherwise carry the variables this process removed.
      def overlay(env = ENV, directory: ENV.fetch("TMUX_TMPDIR"))
        scrub(env).merge("TMUX_TMPDIR" => directory, MARKER => directory)
      end

      # Every socket under the directory, at any depth. Each test here puts its
      # own server on a socket in a directory of its own, so a socket anywhere
      # in the sandbox, whether tmux chose it or a test named it with -S, is a
      # server no test stopped. A link is not followed: its target is a socket
      # in some other tree.
      def leaks(directory)
        Dir.glob("**/*", File::FNM_DOTMATCH, base: directory).select { |path| socket?(File.join(directory, path)) }.sort
      end

      # Stops the server behind each socket with that tmux and removes the
      # directory unless one still answers. The Release names what it found.
      def release(directory, tmux: ENV.fetch("LIBTMUX_TEST_TMUX", "tmux"), wait: STOP_SECONDS)
        found = leaks(directory)
        answering = found.reject { |path| stop(File.join(directory, path), tmux, wait) }
        remove(directory) if answering.empty?
        Release.new(found, answering)
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
        stat = File.stat(directory) if File.directory?(directory)
        return "the sandbox directory is missing or belongs to another user" unless stat&.owned?
        return "the sandbox directory is open to group or others" unless (stat.mode & 0o077).zero?
      end

      def create(roots)
        root = roots.find do |path|
          path.bytesize + NAME_BYTES <= MAX_BYTES && File.directory?(path) && File.writable?(path)
        end
        raise Refused, "no temporary directory is short enough for a tmux socket path; set TMPDIR to a shorter one" unless root

        Dir.mktmpdir(PREFIX, root)
      rescue SystemCallError
        raise Refused, "cannot make a private directory for TMUX_TMPDIR"
      end

      def remove(directory)
        FileUtils.rm_rf(directory) if File.basename(directory).start_with?(PREFIX)
      end

      def socket?(path)
        File.lstat(path).socket?
      rescue SystemCallError
        false
      end

      # kill-server waits for the server to reply, so a server that never does
      # would hold the run for as long as the client lives. The client is
      # killed once the wait is over and the socket then counts as answering.
      def kill_server(socket, tmux, wait)
        pid = Process.spawn(scrub(ENV), tmux, "-S", socket, "kill-server", out: File::NULL, err: File::NULL)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
        until Process.wait(pid, Process::WNOHANG)
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            Process.kill("KILL", pid)
            Process.wait(pid)
            return
          end
          sleep 0.02
        end
      rescue SystemCallError
        nil
      end

      # True once nothing answers on the socket. A server leaves a moment
      # after kill-server returns, so the connection is retried until it fails.
      def stop(socket, tmux, wait)
        kill_server(socket, tmux, wait)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
        while answering?(socket)
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.02
        end
        true
      end

      # Only a refusal or a missing path shows that no server is behind the
      # socket. Any other outcome, a full backlog or a path too long to
      # connect to, leaves the server unproven gone.
      def answering?(socket)
        client = Socket.new(:UNIX, :STREAM)
        client.connect_nonblock(Socket.pack_sockaddr_un(socket))
        true
      rescue Errno::ECONNREFUSED, Errno::ENOENT, Errno::ENOTSOCK
        false
      rescue SystemCallError, ArgumentError
        true
      ensure
        client&.close
      end

      # Minitest runs its tests inside its own exit handler, so a handler
      # registered after it would run first and remove the directory early.
      def clean_up_after(directory)
        owner = Process.pid
        cleanup = lambda do
          next unless Process.pid == owner

          released = release(directory)
          next if released.clean?

          warn released.message(directory)
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
