# frozen_string_literal: true

require "libtmux/errors"
require "libtmux/child"

module LibTmux
  class CommandResult
    attr_reader :stdout, :stderr, :status, :elapsed_seconds, :pid, :argv

    def initialize(stdout:, stderr:, status:, elapsed_seconds:, pid:, argv:)
      @stdout = stdout.b.freeze
      @stderr = stderr.b.freeze
      @status = status
      @elapsed_seconds = elapsed_seconds
      @pid = pid
      @argv = argv.map { |argument| argument.dup.freeze }.freeze
      freeze
    end

    def success?
      status.success?
    end

    def delivery
      :observed
    end

    def text(invalid: :strict)
      raise ArgumentError, "invalid text policy" unless [:strict, :replace].include?(invalid)

      text = stdout.dup.force_encoding(Encoding::UTF_8)
      return text.scrub if invalid == :replace
      return text if text.valid_encoding?

      raise FieldDecodeError.new("command stdout is not valid UTF-8", delivery: delivery, phase: :decode, pid: pid)
    end

    def inspect
      "#<#{self.class} pid=#{pid} exitstatus=#{status.exitstatus} stdout_bytes=#{stdout.bytesize} stderr_bytes=#{stderr.bytesize}>"
    end
  end

  class Cancellation
    attr_reader :reader

    def initialize
      @reader, @writer = IO.pipe
      @mutex = Mutex.new
      @cancelled = false
      @creator_pid = Process.pid
    end

    def cancel
      ensure_owner
      @mutex.synchronize do
        return if @cancelled

        @cancelled = true
        @writer.write_nonblock("x", exception: false)
      end
    end

    def cancelled?
      ensure_owner
      @mutex.synchronize { @cancelled }
    end

    def close
      return detach unless @creator_pid == Process.pid

      cancel
      @mutex.synchronize do
        [@reader, @writer].each { |io| io.close unless io.closed? }
      end
    end

    private

    def detach
      raise ArgumentError, "only a forked child may detach this token" if @creator_pid == Process.pid

      [@reader, @writer].each { |io| io.close unless io.closed? }
      nil
    end

    def ensure_owner
      raise ClosedError.new("cancellation token belongs to another process", phase: :admission) unless @creator_pid == Process.pid
    end
  end

  module Internal
    Cancellation = LibTmux::Cancellation

    class ProcessExecutor
      def initialize(stdout_limit: 1 << 20, stderr_limit: 1 << 18, input_limit: 1 << 20, argv_limit: 1 << 18, cleanup_timeout: 0.5, drain_timeout: 0.5)
        [stdout_limit, stderr_limit, input_limit, argv_limit].each do |limit|
          raise ArgumentError, "byte limits must be nonnegative integers" unless limit.is_a?(Integer) && limit >= 0
        end
        [cleanup_timeout, drain_timeout].each do |timeout|
          raise ArgumentError, "cleanup and drain deadlines must be positive and finite" unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
        end
        @limits = {stdout: stdout_limit, stderr: stderr_limit, input: input_limit, argv: argv_limit}.freeze
        @cleanup_timeout = cleanup_timeout
        @drain_timeout = drain_timeout
      end

      def run(argv, input: "".b, env: {}, timeout: 5.0, cancel: nil)
        Execution.new(argv, input, env, timeout, cancel, @limits, @cleanup_timeout, @drain_timeout).call
      end

      class Execution
        CHUNK_BYTES = 16_384

        def initialize(argv, input, env, timeout, cancel, limits, cleanup_timeout, drain_timeout)
          @started = monotonic
          unless argv.is_a?(Array) && !argv.empty? && argv.all? { |argument| argument.is_a?(String) && !argument.include?("\0") }
            raise ArgumentError, "argv must contain strings without NUL"
          end
          raise ArgumentError, "input must be a String" unless input.is_a?(String)
          raise ArgumentError, "timeout must be finite" unless timeout.is_a?(Numeric) && timeout.finite?
          if input.bytesize > limits.fetch(:input) || argv.sum { |argument| argument.bytesize + 1 } > limits.fetch(:argv)
            raise CapacityError.new("command input exceeded its byte limit", delivery: :not_sent, phase: :admission)
          end

          @argv = argv.map { |argument| argument.dup.freeze }.freeze
          @input = input.b.freeze
          @env = env.merge("TMUX" => nil, "TMUX_PANE" => nil)
          @deadline = @started + timeout
          @cancel = cancel
          @limits = limits
          @cleanup_timeout = cleanup_timeout
          @drain_timeout = drain_timeout
          @process_wait = ProcessWait.new
          @owned = []
          @buffers = {stdout: +"".b, stderr: +"".b}
          @offset = 0
        end

        def call
          error = nil
          result = nil
          begin
            Thread.handle_interrupt(Exception => :never) do
              begin
                check_deadline(:admission)
                check_cancel(:admission)
                spawn
                Thread.handle_interrupt(Exception => :immediate) { result = communicate }
              rescue Exception => failure
                error = failure
              ensure
                cleanup_errors = retire
                if error.is_a?(Error)
                  error.send(:attach_cleanup_errors, cleanup_errors)
                elsif error.nil? && !cleanup_errors.empty?
                  error = TransportError.new("command cleanup failed", **details(:retire), cleanup_errors: cleanup_errors)
                end
              end
            end
          rescue Exception => deferred
            error ||= deferred
          end
          raise error, cause: nil if error

          result
        end

        private

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def pipe
          pair = IO.pipe
          pair.each(&:binmode)
          @owned.concat(pair)
          pair
        end

        def spawn
          child_input, @input_writer = pipe
          @output_reader, child_output = pipe
          @error_reader, child_error = pipe
          @child = OwnedChild.new(@process_wait)
          @exit_reader = @child.reader
          @owned << @exit_reader
          begin
            @pid = Process.spawn(@env, [@argv.first, @argv.first], *@argv.drop(1),
              in: child_input, out: child_output, err: child_error, close_others: true)
          ensure
            @child.spawned(@pid)
          end
          [child_input, child_output, child_error].each(&:close)
          @input_writer.close if @input.empty?
        rescue SystemCallError, IOError => error
          raise TransportError.new("could not start command (#{error.class})", **details(:spawn)), cause: nil
        end

        def communicate
          reading = {@output_reader => :stdout, @error_reader => :stderr}
          loop do
            return result if @status && reading.empty?

            @drain_deadline ||= monotonic + @drain_timeout if @child.observed?
            phase = @drain_deadline ? :drain : (@input_writer.closed? ? :read : :write)
            check_cancel(phase) unless @status
            check_deadline(phase)
            readers = reading.keys
            readers << @exit_reader unless @status
            readers << @cancel.reader if @cancel && !@status
            writers = @input_writer.closed? ? [] : [@input_writer]
            remaining = [@deadline, @drain_deadline || @deadline].min - monotonic
            ready = IO.select(readers, writers, nil, [remaining, 0].max)
            next unless ready

            if ready.first.include?(@exit_reader)
              @exit_reader.read_nonblock(CHUNK_BYTES, exception: false)
              raise @child.observation_error if @child.observation_error

              @child.finish_signalling
              if @child.complete?
                raise @child.retirement_error if @child.retirement_error

                @status = @child.status
                @exit_reader.close
                @input_writer.close unless @input_writer.closed?
                @drain_deadline ||= monotonic + @drain_timeout
              end
            end
            ready.first.each { |io| read_output(io, reading) if reading.key?(io) }
            write_input if ready[1].include?(@input_writer) && !@input_writer.closed?
          end
        rescue SystemCallError, IOError => error
          check_cancel(:read) unless @status
          raise TransportError.new("command I/O failed (#{error.class})", **details(:read)), cause: nil
        end

        def read_output(io, reading)
          stream = reading.fetch(io)
          buffer = @buffers.fetch(stream)
          available = @limits.fetch(stream) - buffer.bytesize
          bytes = io.read_nonblock([CHUNK_BYTES, available + 1].min, exception: false)
          if bytes.nil?
            reading.delete(io)
            io.close
          elsif bytes.is_a?(String)
            raise CapacityError.new("command #{stream} exceeded its byte limit", **details(:read)) if bytes.bytesize > available

            buffer << bytes
          end
        end

        def write_input
          bytes = @input.byteslice(@offset, CHUNK_BYTES)
          written = @input_writer.write_nonblock(bytes, exception: false)
          @offset += written if written.is_a?(Integer)
          @input_writer.close if @offset == @input.bytesize
        rescue Errno::EPIPE
          @input_writer.close
        end

        def check_cancel(phase)
          if @cancel&.cancelled? && !@child&.observed?
            raise Cancelled.new("command was cancelled", **details(phase))
          end
        end

        def check_deadline(phase)
          deadline = [@deadline, @drain_deadline || @deadline].min
          raise DeadlineExceeded.new("command deadline exceeded", **details(phase)) if monotonic >= deadline
        end

        def details(phase)
          {delivery: @status ? :observed : (@pid ? :possibly_sent : :not_sent), phase: phase, pid: @pid}
        end

        def result
          CommandResult.new(**@buffers, status: @status, elapsed_seconds: monotonic - @started, pid: @pid, argv: @argv)
        end

        def retire
          errors = []
          @owned.each do |io|
            io.close unless io.closed?
          rescue IOError, SystemCallError => error
            errors << "descriptor cleanup failed (#{error.class})"
          end
          return errors unless @child

          deadline = monotonic + @cleanup_timeout
          unless @pid
            errors << "command waiter did not finish" unless @child.join(@cleanup_timeout)
            return errors
          end
          unless @child.observed? || @child.observation_error.is_a?(Errno::ECHILD)
            signal("TERM", errors)
            # Reserve the cleanup budget for reaping; timer grace can overrun it.
            signal("KILL", errors) unless @child.observed?
          end
          @child.finish_signalling
          if @child.join([deadline - monotonic, 0].max)
            @status ||= @child.status
          else
            errors << "owned client cleanup remains pending after its deadline"
          end
          errors << "command exit observation failed (#{@child.observation_error.class})" if @child.observation_error
          errors << "command fallback reap failed (#{@child.retirement_error.class})" if @child.retirement_error
          errors
        rescue StandardError => error
          errors << "command waiter failed (#{error.class})"
          errors
        end

        def signal(name, errors)
          @child.signal(name)
        rescue Errno::ESRCH
          nil
        rescue SystemCallError => error
          errors << "client termination failed (#{error.class})"
        end
      end

      private_constant :Execution
    end
  end
end
