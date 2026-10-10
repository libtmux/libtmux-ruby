# frozen_string_literal: true

require "tmpdir"
require "securerandom"
require_relative "errors"

module LibTmux
  # Captured executable, child environment and socket selection. Starts no client.
  class Endpoint
    attr_reader :executable, :socket_path, :environment

    def initialize(socket_path: nil, socket_name: nil, executable: "tmux", socket_directory: nil, env: ENV)
      if !socket_path.nil? && !socket_name.nil?
        raise ArgumentError, "choose at most one socket_path or socket_name"
      end
      captured = capture_environment(env)
      if socket_path.nil? && socket_name.nil?
        socket_path = nonempty(captured["LIBTMUX_SOCKET_PATH"])
        unless socket_path
          socket_name = nonempty(captured["LIBTMUX_SOCKET_NAME"])
          unless socket_name
            context = nonempty(captured["TMUX"])
            context ? socket_path = context_path(context) : socket_name = "default"
          end
        end
      end
      if socket_name
        validate_string(socket_name, "socket_name")
        if socket_name.include?("/") || socket_name.include?("\\") || [".", ".."].include?(socket_name)
          raise ArgumentError, "socket_name must be a single filename"
        end
        directory = socket_directory || nonempty(captured["TMUX_TMPDIR"]) || "/tmp"
        validate_string(directory, "socket_directory")
        raise ArgumentError, "socket_directory must be absolute" unless directory.start_with?("/")
        @named_directory = File.join(directory, "tmux-#{Process.uid}").freeze
        socket_path = File.join(@named_directory, socket_name)
      elsif socket_directory
        raise ArgumentError, "socket_directory applies only to socket_name"
      end
      validate_string(socket_path, "socket_path")
      raise ArgumentError, "socket_path must be absolute" unless socket_path.start_with?("/")
      validate_string(executable, "executable")
      # Let filesystem traversal preserve missing components and symlink parents.
      @socket_path = socket_path.dup.freeze
      @environment = captured.reject { |key, _| ["TMUX", "TMUX_PANE"].include?(key) }.freeze
      @executable = resolve_executable(executable).freeze
      freeze
    end

    def self.from_env(env = ENV, **options)
      new(env: env, **options)
    end

    def ==(other)
      other.is_a?(Endpoint) && executable == other.executable && socket_path == other.socket_path
    end
    alias eql? ==

    def hash
      [self.class, executable, socket_path].hash
    end

    def inspect
      "#<#{self.class} explicit Unix socket>"
    end

    private

    def nonempty(value)
      value unless value.nil? || value.empty?
    end

    def context_path(context)
      prefix, separator, session = context.rpartition(",")
      socket, pid_separator, pid = prefix.rpartition(",")
      unless separator == "," && pid_separator == "," && pid.match?(/\A[0-9]+\z/) && pid.to_i.positive? &&
          (session == "-1" || session.match?(/\A\$?[0-9]+\z/))
        raise ArgumentError, "TMUX must contain an absolute socket, positive PID and valid session field"
      end
      socket
    end

    def capture_environment(env)
      raise ArgumentError, "env must provide a complete environment map" unless env.respond_to?(:to_h)

      env.to_h.each_with_object({}) do |(key, value), captured|
        validate_string(key, "environment key")
        raise ArgumentError, "environment keys cannot contain =" if key.include?("=")
        next if value.nil?
        unless value.is_a?(String) && !value.include?("\0")
          raise ArgumentError, "environment values must be Strings without NUL, or nil"
        end
        captured[key.dup.freeze] = value.dup.freeze
      end
    end

    def prepare_directory
      return unless @named_directory

      begin
        Dir.mkdir(@named_directory, 0o700)
      rescue Errno::EEXIST
        nil
      end
      validate_directory
    end

    def validate_directory
      return unless @named_directory

      stat = File.lstat(@named_directory)
      unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o007).zero?
        raise ArgumentError, "named socket directory must be a real directory owned by the current UID without other-user permissions"
      end
    end

    def validate_string(value, name)
      unless value.is_a?(String) && !value.empty? && !value.include?("\0")
        raise ArgumentError, "#{name} must be a nonempty String without NUL"
      end
    end

    def resolve_executable(value)
      candidates = if value.include?(File::SEPARATOR)
        [File.expand_path(value)]
      else
        @environment.fetch("PATH", "/usr/bin:/bin").split(File::PATH_SEPARATOR).map do |directory|
          File.expand_path(value, directory.empty? ? Dir.pwd : directory)
        end
      end
      candidates.find { |path| File.file?(path) && File.executable?(path) } ||
        raise(ArgumentError, "tmux executable is unavailable")
    end
  end

  module Internal
    # Keep the socket inode alive and route through it; PID timestamps can repeat.
    class SocketIdentity
      attr_reader :key, :environment

      def initialize(endpoint)
        @endpoint = endpoint
        @environment = endpoint.environment
        @owner_pid = Process.pid
        @mutex = Mutex.new
        @closed = false
        @key = SecureRandom.hex(16).freeze
        error = nil
        cleanup_attempted = false
        begin
          Thread.handle_interrupt(Exception => :never) do
            begin
              endpoint.__send__(:validate_directory)
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
