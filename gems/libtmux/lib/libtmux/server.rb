# frozen_string_literal: true

require_relative "endpoint"
require_relative "process"
require_relative "metadata"
require_relative "entity"

module LibTmux
  # Connects to an existing endpoint. Closing retires clients, never the daemon.
  class Server
    attr_reader :endpoint

    def self.open(**options)
      return new(**options) unless block_given?

      failure = nil
      result = nil
      begin
        Thread.handle_interrupt(Exception => :never) do
          server = nil
          begin
            server = new(**options)
            Thread.handle_interrupt(Exception => :immediate) { result = yield server }
          rescue Exception => error
            failure = error
          ensure
            begin
              server&.close
            rescue Exception => cleanup
              if failure.is_a?(Error)
                failure.__send__(:attach_cleanup_errors, ["server close failed (#{cleanup.class})"])
              end
              failure ||= cleanup
            end
          end
        end
      rescue Exception => deferred
        failure ||= deferred
      end
      raise failure if failure

      result
    end

    def initialize(endpoint: nil, socket_path: nil, socket_name: nil, executable: "tmux", max_requests: 32, max_controls: 4, close_timeout: 0.5)
      if endpoint && (socket_path || socket_name || executable != "tmux")
        raise ArgumentError, "endpoint cannot be combined with socket or executable options"
      end
      raise ArgumentError, "endpoint must be an Endpoint" if endpoint && !endpoint.is_a?(Endpoint)
      unless max_requests.is_a?(Integer) && max_requests.positive?
        raise ArgumentError, "max_requests must be a positive Integer"
      end
      unless max_controls.is_a?(Integer) && max_controls.positive?
        raise ArgumentError, "max_controls must be a positive Integer"
      end
      unless close_timeout.is_a?(Numeric) && close_timeout.finite? && close_timeout.positive?
        raise ArgumentError, "close_timeout must be positive and finite"
      end

      @endpoint = endpoint || Endpoint.new(socket_path: socket_path, socket_name: socket_name, executable: executable)
      @owner_pid = Process.pid
      @max_requests = max_requests
      @max_controls = max_controls
      @close_timeout = close_timeout
      @mutex = Mutex.new
      @idle = ConditionVariable.new
      @requests = {}
      @controls = []
      @closed = false
      @executor = Internal::ProcessExecutor.new
      @pin = Internal::SocketIdentity.new(@endpoint)
    end

    # Raw tmux arguments retain tmux's separators and format semantics.
    def run(argv, input: "".b, timeout: 5.0, cancel: nil)
      ensure_owner
      started = monotonic
      validate_argv(argv)
      raise ArgumentError, "raw commands cannot override endpoint flags" if argv.first.start_with?("-")
      raise ArgumentError, "timeout must be finite" unless timeout.is_a?(Numeric) && timeout.finite?
      perform_request(cancel: cancel) do |view|
        @executor.run(@pin.command_prefix + argv, input: input,
          timeout: timeout - (monotonic - started), cancel: view)
      end
    end

    def close
      if Process.pid != @owner_pid
        @requests.each_key(&:detach)
        @controls.each(&:close)
        @requests = {}
        @controls = []
        @closed = true
        @pin.close
        return nil
      end

      Thread.handle_interrupt(Exception => :never) do
        @mutex.synchronize do
          if @requests.value?(Thread.current)
            raise ClosedError.new("cannot close a server from its active request", phase: :retire)
          end
          @closed = true
          deadline = monotonic + @close_timeout
          @controls.each { |control| control.__send__(:request_close) }
          @requests.each_key(&:cancel)
          until @requests.empty?
            remaining = deadline - monotonic
            unless remaining.positive?
              raise DeadlineExceeded.new("server clients have not retired; retry close", phase: :retire, delivery: :possibly_sent)
            end
            @idle.wait(@mutex, remaining)
          end
          @controls.dup.each do |control|
            control.close(timeout: (deadline - monotonic).clamp(0, 0.5))
            @controls.delete(control)
          end
          @pin.close
        end
      end
      nil
    end

    # Returns a frozen local snapshot, including after close. Slots are admitted
    # requests; control connections are retained registrations, not OS clients.
    def diagnostics
      ensure_owner
      @mutex.synchronize do
        {admitted_requests: @requests.length, reserved_process_slots: @requests.length,
          control_connections: @controls.length, closed: @closed,
          limits: {max_requests: @max_requests, max_controls: @max_controls,
            close_timeout: @close_timeout}.freeze}.freeze
      end
    end

    def kill(timeout: 5.0, cancel: nil)
      execute_typed(["kill-server"], timeout: timeout, cancel: cancel)
    end

    def new_session(name:, command:, width: nil, height: nil, window_name: nil, cwd: nil, environment: {}, receipt: false, timeout: 5.0, cancel: nil)
      budget = operation_budget(timeout, cancel)
      arguments = ["new-session", "-d", "-P", "-F", creation_format(:session, receipt), "-s", literal_name(name)]
      arguments.concat(["-n", literal_name(window_name)]) if window_name
      {"-x" => width, "-y" => height}.each do |flag, value|
        next if value.nil?
        raise ArgumentError, "dimensions must be positive integers" unless value.is_a?(Integer) && value.positive?

        arguments.concat([flag, value.to_s])
      end
      arguments.concat(creation_options(cwd: cwd, environment: environment))
      create_entity(:session, arguments + ["--"] + pane_command(command), receipt: receipt, **budget.options)
    end

    def list_sessions(timeout: 5.0, cancel: nil)
      list_entities(:session, [], global: true, timeout: timeout, cancel: cancel)
    end

    def list_windows(timeout: 5.0, cancel: nil)
      list_entities(:window, ["-a"], global: true, timeout: timeout, cancel: cancel)
    end

    def list_panes(timeout: 5.0, cancel: nil)
      list_entities(:pane, ["-a"], global: true, timeout: timeout, cancel: cancel)
    end

    def session(ref)
      resolve(ref, :session)
    end

    def window(ref)
      resolve(ref, :window)
    end

    def pane(ref)
      resolve(ref, :pane)
    end

    def open_control(session:, **options)
      session_id = target(session, :session)
      failure = nil
      result = nil
      connection = nil
      keep = false
      begin
        Thread.handle_interrupt(Exception => :never) do
          begin
            @mutex.synchronize do
              ensure_open
              @controls.reject!(&:closed?)
              if @controls.length >= @max_controls
                raise CapacityError.new("server control capacity is exhausted", phase: :admission)
              end
              connection = ControlConnection.new(binding: @pin, session_id: session_id, **options)
              @controls << connection
            end
            if block_given?
              Thread.handle_interrupt(Exception => :immediate) { result = yield connection }
            else
              Thread.handle_interrupt(Exception => :immediate) { nil }
              result = connection
              keep = true
            end
          rescue Exception => error
            failure = error
          ensure
            if connection && !keep
              begin
                connection.close(timeout: [@close_timeout, 0.5].min)
                @mutex.synchronize { @controls.delete(connection) }
              rescue Exception => cleanup
                failure.__send__(:attach_cleanup_errors, ["control close failed (#{cleanup.class})"]) if failure.is_a?(Error)
                failure ||= cleanup
              end
            end
          end
        end
      rescue Exception => deferred
        failure ||= deferred
      end
      raise failure if failure

      result
    end

    def snapshot(**options)
      ensure_owner
      @mutex.synchronize { ensure_open }
      Internal::Capture.new(self, binding_key: @pin.key).call(**options)
    end

    def search_panes(where: {}, pushdown: :auto, **options)
      Internal::SourceQuery.new(:pane, where: where, pushdown: pushdown).execute(self, **options)
    end

    def explain_panes(where: {}, pushdown: :auto)
      Internal::SourceQuery.new(:pane, where: where, pushdown: pushdown).explain
    end

    private

    class OperationBudget
      def initialize(timeout, cancel, clock)
        raise ArgumentError, "timeout must be finite" unless timeout.is_a?(Numeric) && timeout.finite?
        if cancel && (!cancel.respond_to?(:reader) || !cancel.respond_to?(:cancelled?))
          raise ArgumentError, "cancel must provide a cancellation reader and state"
        end
        @clock, @cancel = clock, cancel
        @deadline = clock.call + timeout
        @dispatched = false
      end

      def options
        delivery = @dispatched ? :possibly_sent : :not_sent
        raise Cancelled.new("operation was cancelled", phase: :admission, delivery: delivery) if @cancel&.cancelled?

        remaining = @deadline - @clock.call
        unless remaining.positive?
          raise DeadlineExceeded.new("operation deadline elapsed", phase: :admission, delivery: delivery)
        end
        @dispatched = true
        {timeout: remaining, cancel: @cancel}
      end
    end
    private_constant :OperationBudget

    def operation_budget(timeout, cancel)
      OperationBudget.new(timeout, cancel, method(:monotonic))
    end

    class CancellationView
      def initialize(owned, external)
        @owned = owned
        @external = external
      end

      def reader
        @owned.reader
      end

      def cancelled?
        @owned.cancelled? || !!@external&.cancelled?
      end
    end
    private_constant :CancellationView

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def ensure_owner
      unless Process.pid == @owner_pid
        raise ClosedError.new("server belongs to another process", phase: :admission)
      end
    end

    # Borrowing adapters may copy these references, but must not suspend or do I/O.
    def with_bound_endpoint
      ensure_owner
      @mutex.synchronize do
        ensure_open
        yield @endpoint, @pin
      end
    end

    def perform_request(cancel:)
      ensure_owner
      if cancel && (!cancel.respond_to?(:reader) || !cancel.respond_to?(:cancelled?))
        raise ArgumentError, "cancel must provide a cancellation reader and state"
      end

      failure = nil
      result = nil
      begin
        Thread.handle_interrupt(Exception => :never) do
          owned = nil
          watcher = nil
          begin
            @mutex.synchronize do
              ensure_open
              if @requests.length >= @max_requests
                raise CapacityError.new("server request capacity is exhausted", phase: :admission)
              end
              owned = Internal::Cancellation.new
              @requests[owned] = Thread.current
            end
            if cancel
              watcher = Thread.new do
                Thread.current.report_on_exception = false
                IO.select([cancel.reader, owned.reader]) unless cancel.cancelled?
                owned.cancel if cancel.cancelled?
              rescue IOError, SystemCallError
                owned.cancel
              end
            end
            view = CancellationView.new(owned, cancel)
            Thread.handle_interrupt(Exception => :immediate) do
              result = yield view
            end
          rescue Exception => error
            failure = error
          ensure
            cleanup_errors = retire_request(owned, watcher) if owned
            if cleanup_errors && !cleanup_errors.empty?
              if failure.is_a?(Error)
                failure.__send__(:attach_cleanup_errors, cleanup_errors)
              elsif failure.nil?
                failure = TransportError.new("server request cleanup failed", phase: :retire,
                  delivery: result ? :observed : :possibly_sent, cleanup_errors: cleanup_errors)
              end
            end
          end
        end
      rescue Exception => deferred
        failure ||= deferred
      end
      raise failure if failure

      result
    end

    def retire_request(owned, watcher)
      errors = []
      begin
        owned.cancel
        watcher&.join(@close_timeout) || errors << "cancellation watcher did not retire" if watcher
      rescue Exception => error
        errors << "cancellation watcher failed (#{error.class})"
      ensure
        begin
          owned.close
        rescue Exception => error
          errors << "cancellation descriptors failed to close (#{error.class})"
        ensure
          @mutex.synchronize do
            @requests.delete(owned)
            @idle.broadcast
          end
        end
      end
      errors
    end

    def ensure_open
      raise ClosedError.new("server is closed", phase: :admission) if @closed
    end

    def validate_argv(argv)
      unless argv.is_a?(Array) && !argv.empty? && argv.all? { |value| value.is_a?(String) && !value.include?("\0") }
        raise ArgumentError, "argv must be a nonempty Array of Strings without NUL"
      end
    end

    def execute_typed(arguments, **options)
      result = run(encode_arguments(arguments), **options)
      raise CommandError.new(result: result, phase: :command) unless result.success?

      result
    end

    def encode_arguments(arguments)
      validate_argv(arguments)
      # cmd_parse_from_arguments consumes one backslash before a final ';'.
      arguments.map { |value| value.end_with?(";") ? value[0...-1] + "\\;" : value }
    end

    def literal_name(name)
      unless name.is_a?(String) && !name.empty? && !name.include?("\0")
        raise ArgumentError, "name must be a nonempty String without NUL"
      end
      name.gsub("#", "##")
    end

    def pane_command(command)
      validate_argv(command)
      raise ArgumentError, "command executable must not be empty" if command.first.empty?

      # A single tmux argument would invoke $SHELL -c instead of execvp.
      command.length == 1 ? ["/usr/bin/env", "--", *command] : command
    end

    def target(ref, kind)
      ensure_owner
      @mutex.synchronize { ensure_open }
      unless ref.is_a?(EntityRef) && ref.kind == kind && ref.binding_key == @pin.key
        raise TargetNotFoundError.new("target does not belong to this server binding", phase: :admission)
      end
      ref.id
    end

    def resolve(ref, kind)
      target(ref, kind)
      entity_class(kind).__send__(:new, self, ref)
    end

    def entity_class(kind)
      {session: Session, window: Window, pane: Pane, window_link: WindowLink}.fetch(kind)
    end

    def build_entity(kind, id)
      ref = EntityRef.__send__(:new, binding_key: @pin.key, kind: kind, id: id)
      entity_class(kind).__send__(:new, self, ref)
    end

    def id_format(kind)
      "\#{n:#{kind}_id}:\#{#{kind}_id}"
    end

    def creation_format(kind, receipt)
      raise ArgumentError, "receipt must be Boolean" unless [true, false].include?(receipt)
      return id_format(kind) unless receipt

      kinds = kind == :session ? %i[session window pane] : %i[window pane]
      kinds.map { |child| id_format(child) }.join
    end

    def create_entity(kind, arguments, receipt: false, **options)
      result = execute_typed(arguments, **options)
      kinds = receipt ? (kind == :session ? %i[session window pane] : %i[window pane]) : [kind]
      rows = Internal::Metadata.decode(result.stdout, fields: kinds.length, max_rows: 1)
      raise ProtocolError.new("tmux did not return the created #{kind} ID", delivery: :observed, phase: :decode) unless rows.length == 1

      entities = kinds.zip(rows.first).to_h { |child, id| [child, build_entity(child, id)] }
      return entities.fetch(kind) unless receipt

      CreationReceipt.__send__(:new, entity: entities.fetch(kind), window: entities.fetch(:window),
        pane: entities.fetch(:pane), result: result)
    end

    def list_entities(kind, options, global: false, timeout: 5.0, cancel: nil)
      result = execute_typed(["list-#{kind}s", *options, "-F", id_format(kind)], timeout: timeout, cancel: cancel)
      entities = Internal::Metadata.decode(result.stdout, fields: 1).map { |row| build_entity(kind, row.first) }
      entities = entities.uniq.sort_by { |entity| entity.id[1..].to_i } if global
      entities.freeze
    end

    def creation_options(cwd:, environment:)
      arguments = []
      if cwd
        unless cwd.is_a?(String) && !cwd.empty? && !cwd.include?("\0")
          raise ArgumentError, "cwd must be a nonempty String without NUL"
        end
        directory = File.expand_path(cwd)
        raise ArgumentError, "cwd must name an existing accessible directory" unless File.directory?(directory) && File.executable?(directory)

        # tmux expands -c as a format, while -e values are literal.
        arguments.concat(["-c", directory.gsub("#", "##")])
      end
      raise ArgumentError, "environment must be a Hash" unless environment.is_a?(Hash)

      environment.each do |name, value|
        environment_name(name)
        unless value.is_a?(String) && !value.include?("\0")
          raise ArgumentError, "environment values must be Strings without NUL"
        end
        arguments.concat(["-e", "#{name}=#{value}"])
      end
      arguments
    end

    def create_window(ref, name:, command:, index: nil, cwd: nil, environment: {}, focus: false, receipt: false, timeout: 5.0, cancel: nil)
      budget = operation_budget(timeout, cancel)
      unless index.nil? || (index.is_a?(Integer) && index.between?(0, (1 << 31) - 1))
        raise ArgumentError, "index must be a nonnegative 32-bit Integer"
      end
      raise ArgumentError, "focus must be boolean" unless [true, false].include?(focus)

      destination = target(ref, :session)
      destination += ":#{index}" unless index.nil?
      arguments = ["new-window", *(focus ? [] : ["-d"]), "-P", "-F", creation_format(:window, receipt), "-t", destination, "-n", literal_name(name)]
      arguments.concat(creation_options(cwd: cwd, environment: environment))
      create_entity(:window, arguments + ["--"] + pane_command(command), receipt: receipt, **budget.options)
    end

    def split_window(ref, direction:, command:, size: nil, cwd: nil, environment: {}, focus: false, timeout: 5.0, cancel: nil)
      budget = operation_budget(timeout, cancel)
      flag = {horizontal: "-h", vertical: "-v"}.fetch(direction) do
        raise ArgumentError, "direction must be :horizontal or :vertical"
      end
      unless size.nil? || (size.is_a?(Integer) && size.between?(1, (1 << 31) - 1)) ||
          (size.is_a?(String) && size.match?(/\A(?:[1-9][0-9]?|100)%\z/))
        raise ArgumentError, "size must be positive cells or a percentage from 1% to 100%"
      end
      raise ArgumentError, "focus must be boolean" unless [true, false].include?(focus)
      unless ref.is_a?(EntityRef) && [:window, :pane].include?(ref.kind)
        raise ArgumentError, "split target must be a window or pane ref"
      end

      arguments = ["split-window", *(focus ? [] : ["-d"]), flag, "-P", "-F", id_format(:pane), "-t", target(ref, ref.kind)]
      arguments.concat(["-l", size.to_s]) if size
      arguments.concat(creation_options(cwd: cwd, environment: environment))
      create_entity(:pane, arguments + ["--"] + pane_command(command), **budget.options)
    end
  end
end
