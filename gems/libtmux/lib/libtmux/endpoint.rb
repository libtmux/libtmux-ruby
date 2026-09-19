# frozen_string_literal: true

require "tmpdir"
require "securerandom"
require_relative "errors"

module LibTmux
  # Explicit executable and socket selection. Construction starts no clients.
  class Endpoint
    attr_reader :executable, :socket_path

    def initialize(socket_path: nil, socket_name: nil, executable: "tmux", socket_directory: nil)
      unless [socket_path, socket_name].count { |value| !value.nil? } == 1
        raise ArgumentError, "choose exactly one socket_path or socket_name"
      end
      if socket_name
        validate_string(socket_name, "socket_name")
        if socket_name.include?("/") || [".", ".."].include?(socket_name)
          raise ArgumentError, "socket_name must be a single filename"
        end
        directory = socket_directory || ENV["TMUX_TMPDIR"] || "/tmp"
        validate_string(directory, "socket_directory")
        socket_path = File.join(directory, "tmux-#{Process.uid}", socket_name)
      elsif socket_directory
        raise ArgumentError, "socket_directory applies only to socket_name"
      end
      validate_string(socket_path, "socket_path")
      validate_string(executable, "executable")
      @socket_path = File.expand_path(socket_path).freeze
      @executable = resolve_executable(executable).freeze
      freeze
    end

    def self.from_env(env = ENV, **options)
      if env["TMUX"] && !env["TMUX"].empty?
        new(socket_path: env["TMUX"].split(",", 3).first, **options)
      else
        new(socket_name: "default", socket_directory: env["TMUX_TMPDIR"], **options)
      end
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

    def validate_string(value, name)
      unless value.is_a?(String) && !value.empty? && !value.include?("\0")
        raise ArgumentError, "#{name} must be a nonempty String without NUL"
      end
    end

    def resolve_executable(value)
      candidates = if value.include?(File::SEPARATOR)
        [File.expand_path(value)]
      else
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map do |directory|
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
      attr_reader :key

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
