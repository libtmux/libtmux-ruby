# frozen_string_literal: true

require "libtmux/mcp/process_identity"

module LibTmux
  module MCP
    class Observation
      StaleCursor = Class.new(LibTmux::Error)
      LostObservation = Class.new(LibTmux::Error)
      module CleanupDetails
        attr_reader :mcp_cleanup_errors
      end
      Capture = Data.define(:rows, :capture_id, :reference, :options, :process, :expires, :bytes, :encoding) do
        def close
          process.close
        end
      end

      Retirement = Data.define(:owner, :tasks, :subscription, :control) do
        def complete?
          tasks.all?(&:finished?) && (!subscription || subscription.closed?) && (!control || control.closed?)
        end

        def close(deadline:)
          errors = owner.__send__(:retire_attempt, tasks, subscription: subscription, control: control, deadline: deadline)
          errors << "observation consumers remain pending" unless complete?
          raise TransportError.new("observation consumers are still retiring", phase: :retire, cleanup_errors: errors) unless errors.empty?

          nil
        end
      end

      def self.capabilities(version)
        parsed = /\A(\d+)\.(\d+)/.match(version)
        native = case RUBY_PLATFORM
        when /\A(?:x86_64|aarch64)-linux/
          ["64-bit Linux with peer pidfds (kernel >= 6.6)", "same PID namespace and matching procfs"]
        when /\A(?:x86_64|arm64)-darwin/
          ["64-bit Darwin with kqueue NOTE_EXIT/NOTE_REAP", "fresh pinned-route daemon identity"]
        end
        conditional = native && Fiddle::SIZEOF_LONG == 8 && parsed && ([parsed[1].to_i, parsed[2].to_i] <=> [3, 3]) >= 0
        {"screen" => "bounded_rows", "history_continuity" => "unknown",
          "process_cursor" => conditional ? "conditional" : "unsupported",
          "requirements" => ["tmux >= 3.3", *(native || ["supported 64-bit Linux or Darwin process identity backend"]),
            "live pane process", "empty effective capture hook"],
          "wait_conditions" => %w[screen_contains process_exit]}
      end

      def initialize(server:, arguments:, timeout:, cancel:, max_snapshot_bytes:)
        @server, @arguments, @cancel = server, arguments, cancel
        @started = clock
        @budget = server.__send__(:operation_budget, [timeout, arguments.fetch("timeout", timeout)].min, cancel)
        @max_snapshot_bytes = max_snapshot_bytes
        @owned = []
        @retirements = []
      end

      def close(timeout: 0.4)
        errors = []
        deadline = clock + timeout
        @retirements.dup.each do |group|
          begin
            group.close(deadline: deadline)
          rescue TransportError => error
            errors.concat(error.cleanup_errors)
          ensure
            @retirements.delete(group) if group.complete?
          end
        end
        (@retirements.empty? ? @owned.dup : []).each do |resource|
          begin
            resource.close
            @owned.delete(resource)
          rescue Exception => error
            errors << "observer resource cleanup failed (#{error.class})"
            errors.concat(error.cleanup_errors) if error.is_a?(LibTmux::Error)
          end
        end
        raise TransportError.new("observer resources remain pending", phase: :retire, cleanup_errors: errors) unless errors.empty?

        nil
      end

      def cleanup_remaining
        @cleanup_deadline ||= clock + 0.4
        [@cleanup_deadline - clock, 0].max
      end

      def capture(previous: nil, expires:)
        identity = entry = nil
        response = with_cancellation do
          reference = @arguments.fetch("target").transform_values { |value| value.is_a?(String) ? value.dup : value }
          if previous
            raise StaleCursor, "cursor target differs" unless reference == previous.reference

            identity = previous.process.retain
            @owned << identity
          end
          snapshot, pane = resolve(reference)
          tracked = previous || @arguments.fetch("track", false)
          if tracked
            require_tracking(snapshot)
            identity ||= acquire_identity(snapshot, pane)
            identity.ensure_live!
          end
          limits = previous ? previous.options : defaults
          rows, encoding, truncated = read_rows(pane, limits, identity)
          id = SecureRandom.hex(16)
          result = state(reference, rows, encoding, truncated, limits, identity, id)
          if previous
            prefix = 0
            suffix = 0
            if previous.encoding == encoding
              prefix += 1 while prefix < [rows.length, previous.rows.length].min && rows[prefix] == previous.rows[prefix]
              suffix += 1 while suffix < [rows.length, previous.rows.length].min - prefix && rows[-suffix - 1] == previous.rows[-suffix - 1]
            end
            result.delete("rows")
            result.merge!("mode" => "delta", "base_capture_id" => previous.capture_id,
              "reset" => prefix.zero? && suffix.zero?, "splice" => {"start" => prefix,
                "delete" => previous.rows.length - prefix - suffix, "rows" => rows.slice(prefix, rows.length - prefix - suffix)})
          end
          if tracked
            result["next_cursor"] = id
            entry = Capture.new(rows: rows, capture_id: id.freeze, reference: freeze_tree(reference),
              options: freeze_tree(limits), process: identity, expires: expires,
              bytes: rows.sum(&:bytesize) + JSON.generate(reference).bytesize + 256, encoding: encoding)
            @owned.delete(identity)
            @owned << entry
            identity = nil
          end
          [result, entry]
        end
        @owned.delete(entry)
        response
      rescue TargetNotFoundError, CommandError => error
        raise StaleCursor.new("cursor process changed", delivery: error.delivery), cause: nil if previous

        raise
      ensure
        # The application retains this observer until its resources retire.
        # Failed cleanup must not mask the first operation error here.
        primary = $!
        begin
          close(timeout: cleanup_remaining)
        rescue TransportError => cleanup
          raise cleanup unless primary

          attach_cleanup(primary, cleanup.cleanup_errors)
        end
      end

      def wait
        identity = control = subscription = nil
        tasks = []
        failure = response = nil
        begin
          response = with_cancellation do
            reference = @arguments.fetch("target")
            condition = @arguments.fetch("condition")
            snapshot, pane = resolve(reference)
            require_tracking(snapshot)
            identity = acquire_identity(snapshot, pane)
            if condition.fetch("type") == "screen_contains"
              link = snapshot.window_links.find { |item| item.window_id == pane.window_id }
              raise TargetNotFoundError.new("pane has no observable session", phase: :admission) unless link

              session = snapshot.sessions.find { |item| item.id == link.session_id }
              control = @server.open_control(session: session.ref)
              subscription = control.subscribe(pane_id: pane.id, max_bytes: 1 << 18, max_events: 256)
              # A completed private boundary proves attach input is being read.
              line = @server.__send__(:tmux_command, [spellings.fetch("if-shell"), "-F", "0", ""])
              control.exchange(line, **@budget.options)
            end
            limits = defaults
            rows, encoding, truncated = read_rows(pane, limits, identity)
            if condition.fetch("type") == "screen_contains" && contains?(rows, encoding, condition.fetch("text"))
              next {"target" => reference, "condition" => "screen_contains",
                "capture" => state(reference, rows, encoding, truncated, limits, identity, SecureRandom.hex(16))}
            end
            changed = ::Async::Notification.new
            pending = nil
            wake = lambda do |value|
              pending = value if pending.nil? || (!pending.is_a?(Exception) && (value.is_a?(Exception) || value == :exited))
              changed.signal
            end
            [[identity.io, :exited], [identity.peer, LostObservation.new("tmux process ended", phase: :observation)]].each do |io, event|
              task = ::Async::Task.new(::Async::Task.current) do
                Fiber.scheduler.io_wait(io, IO::READABLE)
                wake.call(event)
              rescue ::Async::Cancel
                nil
              rescue StandardError => error
                wake.call(error)
              end
              tasks << task
              task.run
            end
            if subscription
              task = ::Async::Task.new(::Async::Task.current) do
                loop do
                  event = subscription.next(timeout: @budget.options.fetch(:timeout))
                  if event.kind == :gap
                    wake.call(LostObservation.new("screen observation has a gap", phase: :observation, delivery: :observed))
                    break
                  end
                  wake.call(:read) if event.kind == :output
                end
              rescue ::Async::Cancel
                nil
              rescue StopIteration
                wake.call(LostObservation.new("screen observation ended", phase: :observation, delivery: :observed))
              rescue StandardError => error
                wake.call(error)
              end
              tasks << task
              task.run
            end
            loop do
              remaining = @budget.options.fetch(:timeout)
              ::Async::Task.current.with_timeout(remaining) { changed.wait } unless pending
              event, pending = pending, nil
              raise event if event.is_a?(Exception)

              if event == :exited
                identity.peer_alive!
                unless condition.fetch("type") == "process_exit"
                  raise TargetNotFoundError.new("observed pane process exited", phase: :observation, delivery: :observed)
                end
                break {"target" => reference, "condition" => "process_exit", "process_generation" => identity.generation,
                  "observed_at" => clock, "exit_status" => "unobserved"}
              end
              rows, encoding, truncated = read_rows(pane, limits, identity)
              if contains?(rows, encoding, condition.fetch("text"))
                break {"target" => reference, "condition" => "screen_contains",
                  "capture" => state(reference, rows, encoding, truncated, limits, identity, SecureRandom.hex(16))}
              end
            end
          end
        rescue ::Async::TimeoutError
          failure = DeadlineExceeded.new("observation deadline elapsed", phase: :observation, delivery: :observed)
        rescue Exception => error
          failure = error
        ensure
          errors = retire(tasks, subscription: subscription, control: control)
          begin
            close(timeout: cleanup_remaining)
          rescue TransportError => cleanup
            errors.concat(cleanup.cleanup_errors)
          end
          unless errors.empty?
            attach_cleanup(failure, errors) if failure
            failure ||= TransportError.new("observation cleanup failed", phase: :retire, cleanup_errors: errors)
          end
        end
        raise failure if failure

        response
      end

      private

      def acquire_identity(snapshot, pane)
        identity = ProcessIdentity.acquire(@server, server_pid: snapshot.server_info.fetch(:pid), pane_pid: pane.pid,
          budget: @budget, on_retire: ->(resource) { @owned << resource })
        @owned << identity
        identity
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def defaults
        {"max_lines" => @arguments.fetch("max_lines", 200), "max_bytes" => @arguments.fetch("max_bytes", 65536),
          "history_lines" => @arguments.fetch("history_lines", 0)}
      end

      def resolve(reference)
        snapshot = @server.snapshot(**@budget.options, max_bytes: @max_snapshot_bytes, max_rows: 4096)
        pane = snapshot.panes.find { |record| record.id == reference.fetch("id") }
        unless reference.fetch("generation") == snapshot.binding_key && pane
          raise TargetNotFoundError.new("pane reference is outside this live binding", phase: :admission)
        end
        [snapshot, pane]
      end

      def require_tracking(snapshot)
        version = /\A(\d+)\.(\d+)/.match(snapshot.server_info.fetch(:version))
        unless version && ([version[1].to_i, version[2].to_i] <=> [3, 3]) >= 0
          raise UnsupportedFeatureError.new("process cursors require tmux 3.3 death-status formats", phase: :admission)
        end
      end

      def read_rows(pane, limits, identity)
        identity&.ensure_live!
        names = spellings
        guard = "\#{==:\#{pane_id},#{pane.id}}"
        guard = "\#{&&:#{guard},\#{&&:\#{==:\#{pane_pid},#{identity.pid}},\#{&&:\#{==:\#{pane_dead_status},},\#{==:\#{pane_dead_signal},}}}}" if identity
        body = @server.__send__(:tmux_command, [names.fetch("capture-pane"), "-p", "-t", pane.id,
          "-S", (-limits.fetch("history_lines")).to_s, "-E", "-"])
        # The selected false branch fails parsing, independently of screen bytes.
        failure = @server.__send__(:tmux_command, [names.fetch("capture-pane"), "-t"])
        body = @server.__send__(:tmux_command, [names.fetch("if-shell"), "-F", "-t", pane.id, guard, body, failure])
        hook_error = "libtmux-hook-refused-#{SecureRandom.hex(16)}"
        hook_failure = @server.__send__(:tmux_command, [hook_error])
        begin
          result = @server.__send__(:execute_typed, [names.fetch("if-shell"), "-F", "-t", pane.id,
            '#{==:#{after-capture-pane},}', body, hook_failure], **@budget.options)
        rescue CommandError => error
          if error.result&.stderr&.include?(hook_error)
            raise UnsupportedFeatureError.new("capture hooks prevent isolated screen output", phase: :read, delivery: error.delivery), cause: nil
          end
          raise TargetNotFoundError.new("screen target or process changed", phase: :read, delivery: error.delivery), cause: nil
        end
        identity&.ensure_live!
        @budget.options
        original = result.stdout.lines
        rows = original.last(limits.fetch("max_lines"))
        bytes = rows.join.b
        truncated = rows.length != original.length || bytes.bytesize > limits.fetch("max_bytes")
        bytes = bytes.byteslice(-limits.fetch("max_bytes"), limits.fetch("max_bytes")) if bytes.bytesize > limits.fetch("max_bytes")
        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        encoding = utf8.valid_encoding? ? "utf-8" : "base64"
        rows = (encoding == "utf-8" ? utf8 : bytes).lines.map do |row|
          (encoding == "utf-8" ? row : [row].pack("m0")).freeze
        end.freeze
        [rows, encoding, truncated]
      end

      def spellings
        @spellings ||= @server.__send__(:builtin_spellings, "if-shell", "capture-pane", budget: @budget)
      end

      def contains?(rows, encoding, text)
        rows.map { |row| encoding == "utf-8" ? row.b : row.unpack1("m0") }.join.b.include?(text.b)
      end

      def state(reference, rows, encoding, truncated, limits, identity, id)
        bytes = rows.sum { |row| encoding == "utf-8" ? row.bytesize : row.unpack1("m0").bytesize }
        {"mode" => "snapshot", "target" => reference, "capture_id" => id,
          "process_generation" => identity&.generation, "rows" => rows, "encoding" => encoding,
          "row_count" => rows.length, "bytes" => bytes, "truncated" => truncated,
          "history_continuity" => "unknown", "scope" => limits,
          "interval" => {"clock" => "monotonic_seconds", "started" => @started, "finished" => clock}}
      end

      def with_cancellation
        owner = ::Async::Task.current
        armed = true
        watcher_error = nil
        watcher = ::Async::Task.new(owner) do
          Fiber.scheduler.io_wait(@cancel.reader, IO::READABLE) unless @cancel.cancelled?
          owner.cancel if armed && @cancel.cancelled?
        rescue IOError, SystemCallError
          if armed
            watcher_error = TransportError.new("cancellation observation failed", phase: :observation)
            owner.cancel
          end
        end
        failure = result = nil
        begin
          watcher.run
          result = yield
        rescue ::Async::Cancel => error
          failure = watcher_error || (@cancel.cancelled? ? Cancelled.new("observation cancelled", phase: :read, delivery: :possibly_sent) : error)
        rescue Exception => error
          failure = error
        ensure
          armed = false
          errors = retire([watcher])
          unless errors.empty?
            attach_cleanup(failure, errors) if failure
            failure ||= TransportError.new("cancellation observer cleanup failed", phase: :retire, cleanup_errors: errors)
          end
        end
        raise failure if failure

        result
      end

      def retire(tasks, subscription: nil, control: nil)
        group = Retirement.new(owner: self, tasks: tasks.dup, subscription: subscription, control: control)
        @retirements << group
        group.close(deadline: clock + cleanup_remaining)
        []
      rescue TransportError => error
        error.cleanup_errors.dup
      ensure
        @retirements.delete(group) if group&.complete?
      end

      def retire_attempt(tasks, subscription:, control:, deadline:)
        errors = []
        tasks.each do |task|
          begin
            task.cancel unless task.finished?
          rescue ::Async::Cancel
            retry if clock < deadline
            errors << "observer cancellation remained interrupted"
          rescue StandardError => error
            errors << "observer cancellation failed (#{error.class})"
          end
        end
        begin
          subscription&.close
        rescue ::Async::Cancel
          retry if clock < deadline
          errors << "subscription retirement remained interrupted"
        rescue StandardError => error
          errors << "subscription retirement failed (#{error.class})"
        end
        if control
          begin
            control.close(timeout: [[deadline - clock, 0].max, 0.4].min)
          rescue ::Async::Cancel
            retry if clock < deadline
            errors << "control retirement remained interrupted"
          rescue StandardError => error
            errors << "control retirement failed (#{error.class})"
          end
        end
        tasks.each do |task|
          begin
            task.wait(timeout: [deadline - clock, 0].max) unless task.finished?
          rescue ::Async::Cancel
            retry if clock < deadline
            errors << "observer retirement remained interrupted"
          rescue StandardError => error
            errors << "observer retirement failed (#{error.class})"
          end
          errors << "observer task remains pending" unless task.finished?
        end
        errors
      end

      def attach_cleanup(failure, errors)
        if failure.is_a?(LibTmux::Error)
          failure.__send__(:attach_cleanup_errors, errors)
        else
          failure.extend(CleanupDetails)
          failure.instance_variable_set(:@mcp_cleanup_errors, ((failure.mcp_cleanup_errors || []) + errors).freeze)
        end
      end

      def freeze_tree(value)
        case value
        when Hash then value.each { |key, item| key.freeze; freeze_tree(item) }
        when Array then value.each { |item| freeze_tree(item) }
        end
        value.freeze
      end
    end
    private_constant :Observation
  end
end
