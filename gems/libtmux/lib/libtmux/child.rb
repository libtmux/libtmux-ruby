# frozen_string_literal: true

require "libtmux/process_wait"

module LibTmux
  module Internal
    # The native observer never reaps until the I/O owner retires signalling.
    # Its pipe reports latched state; transport readers and writers stay outside.
    class OwnedChild
      attr_reader :pid, :reader

      def initialize(process_wait = ProcessWait.new)
        @mutex, @changed = Mutex.new, ConditionVariable.new
        @launched, @retirement = Queue.new, Queue.new
        @reader, @writer = IO.pipe
        @reader.binmode
        @writer.binmode
        @creator_pid = Process.pid
        @observer = Thread.new { observe(process_wait) }
      rescue Exception
        [@reader, @writer].compact.each { |io| io.close unless io.closed? }
        raise
      end

      def spawned(pid)
        Thread.handle_interrupt(Exception => :never) do
          @mutex.synchronize do
            raise ArgumentError, "child ownership was already published" if @published

            @published = true
            @pid = pid
          end
          @launched << pid
        end
      end

      def observed?
        @mutex.synchronize { !!@observed }
      end

      def observation_error
        @mutex.synchronize { @observation_error }
      end

      def retirement_error
        @mutex.synchronize { @retirement_error }
      end

      def status
        @mutex.synchronize { @status }
      end

      def complete?
        @mutex.synchronize { !!@complete }
      end

      def wait_observed(timeout)
        deadline = clock + timeout
        @mutex.synchronize do
          until @observation_complete
            remaining = deadline - clock
            return nil unless remaining.positive?

            @changed.wait(@mutex, remaining)
          end
          self
        end
      end

      def join(timeout)
        @observer.join(timeout) && self
      end

      def signal(name)
        @mutex.synchronize do
          return nil unless @pid && !@signalling_finished && !@observation_error.is_a?(Errno::ECHILD)

          Process.kill(name, @pid)
        end
      rescue Errno::ESRCH
        nil
      end

      def finish_signalling
        Thread.handle_interrupt(Exception => :never) do
          @mutex.synchronize do
            return if @signalling_finished

            @signalling_finished = true
            # Always queue the handoff: observation may fail after the last signal.
            @retirement << true
          end
        end
      end

      def close
        @reader.close unless @reader.closed?
      end

      def detach
        raise ArgumentError, "only a forked child may detach its observer" if Process.pid == @creator_pid

        [@reader, @writer].each { |io| io.close unless io.closed? }
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def observe(process_wait)
        Thread.current.report_on_exception = false
        child = @launched.pop
        return unless child

        begin
          process_wait.observe(child)
          @mutex.synchronize { @observed = true }
        rescue Exception => failure
          @mutex.synchronize { @observation_error = failure }
        ensure
          @mutex.synchronize do
            @observation_complete = true
            @changed.broadcast
          end
          notify
        end
        @retirement.pop
        unless observation_error.is_a?(Errno::ECHILD)
          begin
            Thread.handle_interrupt(Exception => :never) do
              status = Process.wait2(child).last
              @mutex.synchronize { @status = status }
            end
          rescue Exception => failure
            @mutex.synchronize { @retirement_error = failure }
          end
        end
      ensure
        @mutex.synchronize do
          @complete = @observation_complete = true
          @changed.broadcast
        end
        notify
        @writer.close unless @writer.closed?
      end

      def notify
        @writer.write_nonblock("x", exception: false)
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
