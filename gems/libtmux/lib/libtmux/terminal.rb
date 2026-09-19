# frozen_string_literal: true

require "io/console"
require "libtmux/server"
require "libtmux/child"
require "libtmux/operations"

module LibTmux
  # Terminal bytes go directly to the caller's TTY and are not captured.
  class TerminalResult
    attr_reader :status, :pid, :elapsed_seconds

    def initialize(status:, pid:, elapsed_seconds:)
      @status, @pid, @elapsed_seconds = status, pid, elapsed_seconds
      freeze
    end
    private_class_method :new

    def success?
      status.success?
    end

    def delivery
      :observed
    end

    def inspect
      "#<#{self.class} pid=#{pid} exitstatus=#{status.exitstatus}>"
    end
  end

  class Server
    # Resolves the literal selector at dispatch; it is not a client reference.
    def switch_client(client:, session:, timeout: 5.0, cancel: nil)
      budget = operation_budget(timeout, cancel)
      session_id = target(session, :session)
      unless client.is_a?(String) && client.bytesize.between?(1, 1024) && !client.b.include?("\0")
        raise ArgumentError, "client must be a nonempty String of at most 1024 bytes without NUL"
      end
      client = client.b.freeze
      command = builtin_spellings("switch-client", budget: budget).fetch("switch-client")
      execute_typed([command, "-E", "-c", client, "-t", session_id], **budget.options)
    end

    # Blocks until the owned interactive client exits. The caller supplies and
    # retains its TTY. Cancellation detaches this client, not pane commands.
    def attach(session:, terminal:, term:, read_only: false, timeout: nil, cancel: nil)
      started = monotonic
      session_id = target(session, :session)
      unless terminal.is_a?(IO) && !terminal.closed? && terminal.tty?
        raise ArgumentError, "terminal must be an open caller-owned TTY"
      end
      unless term.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9_.+-]{0,127}\z/.match?(term)
        raise ArgumentError, "term must name a terminal type"
      end
      raise ArgumentError, "read_only must be Boolean" unless [true, false].include?(read_only)
      unless timeout.nil? || (timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?)
        raise ArgumentError, "terminal timeout must be positive and finite, or nil"
      end
      argv = @pin.command_prefix + ["attach-session", "-E", *(read_only ? ["-r"] : []), "-t", session_id]
      perform_request(cancel: cancel) do |view|
        Internal.const_get(:TerminalExecution, false).new(argv, terminal, term,
          timeout && timeout - (monotonic - started), view).call
      end
    end
  end

  module Internal
    class TerminalExecution
      def initialize(argv, terminal, term, timeout, cancel)
        @argv, @terminal, @term, @cancel = argv, terminal, term.dup.freeze, cancel
        @started = clock
        @deadline = timeout && @started + timeout
      end

      def call
        failure = result = nil
        begin
          Thread.handle_interrupt(Exception => :never) do
            begin
              check_cancel
              check_deadline
              @tty = @terminal.dup
              @tty.close_on_exec = true
              @mode = @tty.console_mode
              @child = OwnedChild.new
              begin
                @pid = Process.spawn({"TMUX" => nil, "TMUX_PANE" => nil, "TERM" => @term},
                  *@argv, in: @tty, out: @tty, err: @tty, close_others: true)
              rescue SystemCallError, IOError => error
                raise TransportError.new("terminal client could not start (#{error.class})", **details(:spawn)), cause: nil
              ensure
                @child.spawned(@pid)
              end
              Thread.handle_interrupt(Exception => :immediate) { result = await_exit }
            rescue Exception => error
              failure = error
            ensure
              errors = retire
              if failure.is_a?(Error)
                failure.__send__(:attach_cleanup_errors, errors)
              elsif !failure && !errors.empty?
                failure = TransportError.new("terminal cleanup failed", **details(:retire), cleanup_errors: errors)
              end
            end
          end
        rescue Exception => deferred
          failure ||= deferred
        end
        raise failure, cause: nil if failure

        result
      end

      private

      def await_exit
        loop do
          if @child.observed?
            @retire_deadline ||= clock + 0.5
            @child.finish_signalling
          end
          raise @child.observation_error if @child.observation_error
          if @child.complete?
            raise @child.retirement_error if @child.retirement_error

            return TerminalResult.__send__(:new, status: @child.status, pid: @pid, elapsed_seconds: clock - @started)
          end
          check_cancel unless @retire_deadline
          deadline = @retire_deadline || @deadline
          if deadline && clock >= deadline
            raise DeadlineExceeded.new("terminal client exceeded its deadline", **details(:terminal))
          end
          readers = [@child.reader]
          readers << @cancel.reader unless @retire_deadline
          if IO.select(readers, nil, nil, deadline && [deadline - clock, 0].max)
            @child.reader.read_nonblock(16, exception: false)
          end
        end
      rescue SystemCallError, IOError => error
        raise TransportError.new("terminal process observation failed (#{error.class})", **details(:terminal)), cause: nil
      end

      def retire
        errors = []
        deadline = clock + 0.5
        if @child
          attempt(errors, "terminal client retirement") do
            begin
              unless @child.observed? || @child.complete?
                @child.signal("TERM")
                @child.wait_observed(0.05)
                @child.signal("KILL") unless @child.observed? || @child.complete?
              end
            ensure
              @child.finish_signalling
            end
            unless @child.join((deadline - clock).clamp(0, 0.5))
              raise DeadlineExceeded.new("terminal client did not retire", **details(:retire))
            end
            raise @child.retirement_error if @child.retirement_error
            raise @child.observation_error if @child.observation_error
          end
          attempt(errors, "observer close") { @child.close } if @child.complete?
        end
        attempt(errors, "terminal mode restoration") { @tty.console_mode = @mode } if @mode
        attempt(errors, "terminal descriptor close") { @tty.close unless @tty.closed? } if @tty
        errors
      end

      def attempt(errors, operation)
        yield
      rescue Exception => error
        errors << "#{operation} failed (#{error.class})"
      end

      def check_cancel
        raise Cancelled.new("terminal attachment cancelled", **details(:terminal)) if @cancel.cancelled?
      end

      def check_deadline
        if @deadline && clock >= @deadline
          raise DeadlineExceeded.new("terminal attachment deadline elapsed", **details(:admission))
        end
      end

      def details(phase)
        {phase: phase, pid: @pid, delivery: @pid ? :possibly_sent : :not_sent}
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
    private_constant :TerminalExecution
  end
end
