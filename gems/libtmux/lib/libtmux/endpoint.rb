# frozen_string_literal: true

require "tmpdir"
require "securerandom"
require_relative "errors"

module LibTmux
  # Executable and socket selection. Construction starts no clients.
  #
  # {#initialize Endpoint.new} takes a `socket_path:` or a `socket_name:`.
  # With neither, it picks the socket as tmux does when it is given none, and
  # `environment:` (the process environment by default) decides which: the
  # path in `LIBTMUX_SOCKET_PATH`, else the name in `LIBTMUX_SOCKET`, else the
  # socket `TMUX` names when run inside tmux, else tmux's `default` socket. A
  # variable that is empty counts as unset, and a socket given as an argument
  # ignores the variables. {.from_env} skips the `LIBTMUX_*` variables.
  class Endpoint
    attr_reader :executable, :socket_path

    def initialize(socket_path: nil, socket_name: nil, executable: "tmux", socket_directory: nil, environment: ENV)
      unless socket_path.nil? || socket_name.nil?
        raise ArgumentError, "choose at most one socket_path or socket_name"
      end
      origin = path_label = nil
      if socket_path.nil? && socket_name.nil?
        raise ArgumentError, "socket_directory applies only to socket_name" if socket_directory
        socket_path, socket_name, origin = Internal::SocketChoice.call(environment)
      end
      if socket_name
        label = origin || "socket_name"
        validate_string(socket_name, label)
        if socket_name.include?("/") || [".", ".."].include?(socket_name)
          raise ArgumentError, "#{label} must be a single filename"
        end
        directory = socket_directory || Internal::SocketChoice.present(environment["TMUX_TMPDIR"]) || "/tmp"
        validate_string(directory, "socket_directory")
        path_label = socket_directory ? "socket_directory" : "TMUX_TMPDIR"
        socket_path = File.join(directory, "tmux-#{Process.uid}", socket_name)
      elsif socket_directory
        raise ArgumentError, "socket_directory applies only to socket_name"
      end
      validate_string(socket_path, origin || "socket_path")
      validate_string(executable, "executable")
      @socket_path = expand(socket_path, path_label || origin || "socket_path").freeze
      @executable = resolve_executable(executable).freeze
      freeze
    end

    # The socket of the tmux server this process runs inside, else tmux's
    # `default` socket. It ignores `LIBTMUX_SOCKET_PATH` and `LIBTMUX_SOCKET`.
    def self.from_env(env = ENV, **options)
      socket_path, socket_name = Internal::SocketChoice.tmux(env)
      new(socket_path: socket_path, socket_name: socket_name, environment: env, **options)
    end

    def ==(other)
      other.is_a?(Endpoint) && executable == other.executable && socket_path == other.socket_path
    end
    alias eql? ==

    def hash
      [self.class, executable, socket_path].hash
    end

    def inspect
      "#<#{self.class} Unix socket>"
    end

    private

    # File.expand_path puts the user it cannot find in its message, so the
    # message here names the argument or variable instead.
    def expand(path, label, base = nil)
      base ? File.expand_path(path, base) : File.expand_path(path)
    rescue ArgumentError
      raise ArgumentError, "#{label} cannot be expanded to a path; its leading ~ names no home directory"
    end

    def validate_string(value, name)
      unless value.is_a?(String) && !value.empty? && !value.include?("\0")
        raise ArgumentError, "#{name} must be a nonempty String without NUL"
      end
    end

    def resolve_executable(value)
      candidates = if value.include?(File::SEPARATOR)
        [expand(value, "executable")]
      else
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map do |directory|
          expand(value, "executable", directory.empty? ? Dir.pwd : directory)
        end
      end
      candidates.find { |path| File.file?(path) && File.executable?(path) } ||
        raise(ArgumentError, "tmux executable is unavailable")
    end
  end

  module Internal
    # Picks the socket tmux would use if it were given neither -S nor -L, from
    # the variables that stand for them and the ones tmux reads itself: -S
    # beats -L, and -L beats TMUX. Each pick is [path, name, variable], with
    # the variable named so that a bad value is reported by name.
    module SocketChoice
      module_function

      def call(environment)
        if (path = present(environment["LIBTMUX_SOCKET_PATH"]))
          [path, nil, "LIBTMUX_SOCKET_PATH"]
        elsif (name = present(environment["LIBTMUX_SOCKET"]))
          [nil, name, "LIBTMUX_SOCKET"]
        else
          tmux(environment)
        end
      end

      # tmux ignores a TMUX that is empty or starts with a comma, and takes
      # the socket path before the first comma of one that does not.
      def tmux(environment)
        inside = present(environment["TMUX"])
        return [nil, "default", nil] if inside.nil? || inside.start_with?(",")

        [inside.split(",", 2).first, nil, "TMUX"]
      end

      def present(value)
        value if value.is_a?(String) && !value.empty?
      end
    end

    # Keep the socket inode alive and route through it; PID timestamps can repeat.
    class SocketIdentity
      attr_reader :key, :release

      def initialize(endpoint)
        @endpoint = endpoint
        @owner_pid = Process.pid
        @mutex = Mutex.new
        @closed = false
        @key = SecureRandom.hex(16).freeze
        error = nil
        cleanup_attempted = false
        begin
          Thread.handle_interrupt(Exception => :never) do
            begin
              source = File.realpath(endpoint.socket_path)
              unless File.lstat(source).socket?
                raise TargetNotFoundError.new("the selected endpoint is not a Unix socket", phase: :bind)
              end
              make_route(source)
              @stat = File.lstat(@route)
              unless @stat.socket?
                raise TargetNotFoundError.new("the endpoint changed while binding", phase: :bind)
              end
              @prefix = [endpoint.executable, "-u", "-N", "-S", @route].map(&:freeze).freeze
              Thread.handle_interrupt(Exception => :immediate) { nil }
            rescue Exception => failure
              error = binding_error(failure)
              cleanup_after_failure(error)
              cleanup_attempted = true
            end
          end
        rescue Exception => deferred
          error ||= binding_error(deferred)
        end
        if error
          begin
            Thread.handle_interrupt(Exception => :never) { cleanup_after_failure(error) } unless cleanup_attempted
          rescue Exception
            # A second deferred cancellation cannot replace the original failure.
          end
          raise error, cause: nil
        end
      end

      # Records the daemon release that the server version check read through this route.
      def record_release(release)
        @release = release
      end

      def command_prefix
        @mutex.synchronize do
          if @closed || Process.pid != @owner_pid
            raise ClosedError.new("the server binding is closed or belongs to another process", phase: :admission)
          end
          current = File.lstat(@route)
          unless current.socket? && [current.dev, current.ino] == [@stat.dev, @stat.ino]
            raise TargetNotFoundError.new("the retained server route changed", phase: :admission)
          end
          @prefix
        rescue Errno::ENOENT
          raise TargetNotFoundError.new("the retained server route is unavailable", phase: :admission)
        end
      end

      def close
        Thread.handle_interrupt(Exception => :never) do
          @mutex.synchronize do
            return if @closed
            # A fork inherits references, not permission to retire the parent's route.
            remove_route if Process.pid == @owner_pid
            @closed = true
          end
        end
        nil
      end

      def inspect
        "#<#{self.class} #{@closed ? 'closed' : 'bound'}>"
      end

      private

      def cleanup_after_failure(error)
        remove_route
      rescue Exception => cleanup
        if error.is_a?(Error)
          error.send(:attach_cleanup_errors, ["private route cleanup failed (#{cleanup.class})"])
        end
      end

      def binding_error(failure)
        case failure
        when Errno::ENOENT, Errno::ECONNREFUSED
          TargetNotFoundError.new("the selected tmux endpoint is unavailable", phase: :bind)
        when SystemCallError
          UnsupportedFeatureError.new("cannot retain a private route to this Unix socket", phase: :bind)
        else
          failure
        end
      end

      def make_route(source)
        # Prefer an independent temporary directory on the same filesystem.
        roots = [Dir.tmpdir, File.dirname(source)].uniq
        roots.each_with_index do |root, index|
          @directory = Dir.mktmpdir("libtmux-ruby-route-", root)
          @route = File.join(@directory, "socket").freeze
          if @route.bytesize > 103
            remove_route
            next if index < roots.length - 1
            raise UnsupportedFeatureError.new("the private Unix socket path exceeds the platform limit", phase: :bind)
          end
          begin
            File.link(source, @route)
            return
          rescue Errno::EXDEV
            remove_route
            raise if index == roots.length - 1
          end
        end
      end

      def remove_route
        if @route
          begin
            File.unlink(@route)
          rescue Errno::ENOENT
            nil
          end
        end
        if @directory
          begin
            Dir.rmdir(@directory)
          rescue Errno::ENOENT
            nil
          end
        end
      end
    end
  end
end
