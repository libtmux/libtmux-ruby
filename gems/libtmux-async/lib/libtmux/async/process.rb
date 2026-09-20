# frozen_string_literal: true

require "async/notification"
require "libtmux/child"

module LibTmux
  module Async
    class ProcessDriver
      CHUNK = 16_384
      private_constant :CHUNK

      attr_reader :pid, :result

      def initialize(scope, ticket, argv, input, deadline, cancel, limits)
        @scope, @ticket, @argv, @input = scope, ticket, argv, input
        @deadline, @cancel, @limits = deadline, cancel, limits
        @started = clock
        @changed = ::Async::Notification.new
        @tasks, @streams = [], []
        @buffers = {stdout: +"".b, stderr: +"".b}
        @finished_reads = 0
      end

      def call
        failure = nil
        begin
          watch_cancellation
          @scope.__send__(:acquire, @ticket, @deadline, method(:check_cancel))
          check_budget(:spawn)
          check_cancel(:spawn)
          spawn
          start_io
          drive
        rescue ::Async::Cancel
          if observed?
            begin
              drive
            rescue Exception => error
              failure = error
            end
          else
            failure = Cancelled.new("command task was cancelled", **details(:read))
          end
        rescue Exception => error
          failure = error
        ensure
          errors = cleanup
          @scope.__send__(:release_active, @ticket) if retired?
          if failure
            Async.__send__(:attach_cleanup, failure, errors)
          elsif !failure && !errors.empty?
            failure = TransportError.new("Async command cleanup failed", **details(:retire), cleanup_errors: errors)
          end
        end
        raise failure if failure

        @result
      end

      def retired?
        (!@child || @child_joined) && @tasks.all?(&:finished?)
      end

      def cleanup
        @retiring = true
        deadline = @cleanup_deadline ||= clock + @limits.fetch(:cleanup_timeout)
        errors = []
        @tasks.each do |task|
          task.cancel unless task.finished?
        rescue ::Async::Cancel
          retry if clock < deadline
          errors << "I/O task cancellation remains pending"
        rescue Exception => error
          errors << "I/O task cancellation failed (#{error.class})"
        end
        @streams.each do |stream|
          stream.close unless stream.closed?
        rescue IOError, SystemCallError => error
          errors << "command descriptor close failed (#{error.class})"
        end
        if @child
          begin
            if @pid && !@child.observed? && !@child.observation_error.is_a?(Errno::ECHILD)
              @child.signal("TERM")
              # Reserve the cleanup budget for reaping; timer grace can overrun it.
              @child.signal("KILL") unless @child.observed?
            end
          rescue SystemCallError => error
            errors << "owned client termination failed (#{error.class})"
          ensure
            @child.finish_signalling
          end
          cleanup_wait(deadline) { @child.complete? }
          if @child.complete?
            begin
              joined = @child.join([deadline - clock, 0].max)
              @child_joined = !!joined
              errors << "native child observer join remains pending" unless joined
            rescue ::Async::Cancel
              retry if clock < deadline
              errors << "native child observer join was interrupted"
            end
          else
            errors << "owned client reaping remains pending after cleanup deadline"
          end
          errors << "child observation failed (#{@child.observation_error.class})" if @child.observation_error
          errors << "child reaping failed (#{@child.retirement_error.class})" if @child.retirement_error
          @child.close
        end
        @tasks.each do |task|
          begin
            task.wait(timeout: [deadline - clock, 0].max) unless task.finished?
          rescue ::Async::Cancel
            retry if clock < deadline
            errors << "I/O task join was interrupted"
          rescue Exception => error
            errors << "I/O task join failed (#{error.class})"
          end
        end
        errors
      end

      def details(phase)
        {delivery: @result || @status ? :observed : (@pid ? :possibly_sent : :not_sent), phase: phase, pid: @pid}
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def observed?
        !!(@child&.observed? && !@child.observation_error)
      end

      def watch_cancellation
        return unless @cancel

        start_task do
          until @cancel.cancelled?
            Fiber.scheduler.io_wait(@cancel.reader, IO::READABLE)
          end
          @cancelled = true
          @scope.__send__(:notify)
        end
      end

      def check_cancel(phase)
        raise @failure if @failure

        if (@cancelled || @cancel&.cancelled?) && !observed?
          raise Cancelled.new("command was cancelled", **details(phase))
        end
      end

      def check_budget(phase)
        if clock >= [@deadline, @drain_deadline || @deadline].min
          raise DeadlineExceeded.new("command deadline exceeded", **details(phase))
        end
      end

      def pipe
        IO.pipe.tap { |pair| pair.each(&:binmode); @streams.concat(pair) }
      end

      def spawn
        Thread.handle_interrupt(Exception => :never) do
          input, @writer = pipe
          @stdout, output = pipe
          @stderr, error = pipe
          @child = Internal::OwnedChild.new
          begin
            @pid = Process.spawn({"TMUX" => nil, "TMUX_PANE" => nil}, [@argv.first, @argv.first], *@argv.drop(1),
              in: input, out: output, err: error, close_others: true)
          ensure
            @child.spawned(@pid)
          end
          [input, output, error].each(&:close)
        end
      rescue IOError, SystemCallError => error
        raise TransportError.new("could not start command (#{error.class})", **details(:spawn)), cause: nil
      end

      def start_task(&block)
        task = ::Async::Task.new(::Async::Task.current) do
          begin
            block.call
          rescue ::Async::Cancel
            @failure ||= Cancelled.new("command I/O task was cancelled", **details(:read)) unless @retiring
          rescue IOError, SystemCallError => error
            @failure ||= TransportError.new("command I/O failed (#{error.class})", **details(:read)) unless @retiring
          rescue Exception => error
            @failure ||= error unless @retiring
          ensure
            @changed.signal
            @scope.__send__(:notify)
          end
        end
        @tasks << task
        task.run
        task
      end

      def start_io
        start_task { read_stream(@stdout, :stdout) }
        start_task { read_stream(@stderr, :stderr) }
        start_task { write_input }
        start_task do
          until @child.complete?
            @child.reader.read_nonblock(CHUNK, exception: false)
            update_exit
            Fiber.scheduler.io_wait(@child.reader, IO::READABLE) unless @child.complete?
          end
          update_exit
        end
      end

      def read_stream(io, stream)
        buffer = @buffers.fetch(stream)
        loop do
          remaining = @limits.fetch(stream) - buffer.bytesize
          bytes = io.read_nonblock([CHUNK, remaining + 1].min, exception: false)
          case bytes
          when nil then break
          when :wait_readable then Fiber.scheduler.io_wait(io, IO::READABLE)
          when String
            raise CapacityError.new("command #{stream} exceeded its byte limit", **details(:read)) if bytes.bytesize > remaining

            @scope.__send__(:retain_output, @ticket, bytes.bytesize)
            buffer << bytes
          end
        end
        @finished_reads += 1
      ensure
        io.close unless io.closed?
      end

      def write_input
        offset = 0
        while offset < @input.bytesize && !@writer.closed?
          written = @writer.write_nonblock(@input.byteslice(offset, CHUNK), exception: false)
          if written == :wait_writable
            Fiber.scheduler.io_wait(@writer, IO::WRITABLE)
          else
            offset += written
          end
        end
      rescue Errno::EPIPE
        nil
      ensure
        @writer.close unless @writer.closed?
      end

      def update_exit
        if @child.observation_error
          raise TransportError.new("command exit observation failed (#{@child.observation_error.class})", **details(:wait))
        end
        if @child.observed?
          @drain_deadline ||= clock + @limits.fetch(:drain_timeout)
          @child.finish_signalling
        end
        raise TransportError.new("command reaping failed", **details(:wait)) if @child.retirement_error

        @status = @child.status
        @changed.signal
      end

      def drive
        loop do
          begin
            update_exit
            raise @failure if @failure
            if @status && @finished_reads == 2
              check_budget(:publish)
              @result = CommandResult.new(**@buffers, status: @status, pid: @pid, argv: @argv, elapsed_seconds: clock - @started)
              return
            end
            phase = observed? ? :drain : :read
            check_budget(phase)
            check_cancel(phase)
            remaining = [@deadline, @drain_deadline || @deadline].min - clock
            ::Async::Task.current.with_timeout(remaining) { @changed.wait }
          rescue ::Async::TimeoutError
            raise DeadlineExceeded.new("command deadline exceeded", **details(phase))
          rescue ::Async::Cancel
            raise unless observed?
          end
        end
      end

      def cleanup_wait(deadline)
        until yield
          remaining = deadline - clock
          return unless remaining.positive?

          begin
            @child.reader.read_nonblock(CHUNK, exception: false)
            Fiber.scheduler.io_wait(@child.reader, IO::READABLE, remaining) unless yield
          rescue ::Async::Cancel
            next
          rescue IOError, SystemCallError
            return
          end
        end
      end
    end
    private_constant :ProcessDriver
  end
end
