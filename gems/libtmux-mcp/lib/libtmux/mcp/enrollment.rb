# frozen_string_literal: true

require 'libtmux/mcp/observation'
require 'digest/sha2'

module LibTmux
  module MCP
    # Private protocol for an explicitly enrolled interactive shell.
    class EnrollmentRegistry
      Result = Data.define(:stdout, :stderr, :exit_status, :signal, :receipt)

      module RunReceipt
        attr_reader :run_receipt, :run_delivery, :run_completion
      end

      class SocketLease
        def initialize(path)
          @path = path
        end

        def bind
          @listener = UNIXServer.new(@path)
        end

        def close
          failure = nil
          begin
            @listener.close if @listener && !@listener.closed?
          rescue Exception => error
            failure = error
          end
          begin
            File.unlink(@path) if File.exist?(@path)
          rescue Exception => error
            ProcessIdentity.attach_cleanup(failure, ["socket path retirement failed (#{error.class})"]) if failure
            failure ||= error
          end
          raise failure if failure
        end
      end

      class Channel
        def initialize(io)
          @io, @buffer = io, +''.b
        end

        attr_reader :io

        def write(line, budget)
          raise ProtocolError.new('enrollment frame exceeds its limit', phase: :write) if line.bytesize > 1024 || line.include?("\n")

          write_bytes("#{line}\n".b, budget)
        end

        def write_bytes(bytes, budget)
          offset = 0
          while offset < bytes.bytesize
            remaining = budget.options.fetch(:timeout)
            count = @io.write_nonblock(bytes.byteslice(offset, 16_384), exception: false)
            if count == :wait_writable
              Fiber.scheduler.io_wait(@io, IO::WRITABLE, remaining)
            else
              offset += count
            end
          end
        end

        def read_bytes(length, budget)
          result = @buffer.slice!(0, length)
          while result.bytesize < length
            remaining = budget.options.fetch(:timeout)
            bytes = @io.read_nonblock([length - result.bytesize, 16_384].min, exception: false)
            if bytes == :wait_readable
              Fiber.scheduler.io_wait(@io, IO::READABLE, remaining)
            elsif bytes
              result << bytes
            else
              raise ClosedError.new('shell protocol channel closed', phase: :read, delivery: :possibly_sent)
            end
          end
          result.freeze
        end

        def read(budget)
          loop do
            if (ending = @buffer.index("\n"))
              return @buffer.slice!(0, ending + 1).chomp
            end
            raise ProtocolError.new('enrollment frame exceeds its limit', phase: :read) if @buffer.bytesize >= 1024

            remaining = budget.options.fetch(:timeout)
            bytes = @io.read_nonblock(1024 - @buffer.bytesize, exception: false)
            if bytes == :wait_readable
              Fiber.scheduler.io_wait(@io, IO::READABLE, remaining)
            elsif bytes
              @buffer << bytes
            else
              raise ClosedError.new('shell protocol channel closed', phase: :read)
            end
          end
        end

        def close
          @io.close unless @io.closed?
        end
      end

      class Invitation
        attr_reader :reference, :capture, :listener, :path, :token, :expires_at

        def initialize(reference:, capture:, listener:, path:, expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60)
          @reference, @capture, @listener, @path = reference, capture, listener, path.freeze
          @token = SecureRandom.hex(16).freeze
          @expires_at = expires_at
        end

        def shell_arguments
          raise ClosedError.new('shell invitation is closed', phase: :admission) if @released
          raise DeadlineExceeded.new('shell invitation expired', phase: :admission) if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @expires_at

          roots = %w[libtmux fiddle digest].flat_map { |name| Gem.loaded_specs.fetch(name).full_require_paths }
          roots.concat([RbConfig::CONFIG.fetch('rubylibdir'), RbConfig::CONFIG.fetch('rubyarchdir')])
          raise UnsupportedFeatureError.new('helper load paths are unsupported', phase: :admission) if roots.any? { |path| path.include?(File::PATH_SEPARATOR) }

          [File.expand_path('shell/integration.zsh', __dir__), @path, @token, Gem.ruby,
            File.expand_path('shell/prepare.rb', __dir__), roots.uniq.join(File::PATH_SEPARATOR)].map { |value| value.dup.freeze }.freeze
        end

        def inspect
          "#<#{self.class} closed=#{!!@released}>"
        end

        def close
          @listener.close unless @listener.closed?
          File.unlink(@path) if File.exist?(@path)
          @capture.close unless @released
          @released = true
        end
      end

      class Enrollment
        attr_reader :reference, :capture, :channel, :epoch
        attr_accessor :prepared

        def initialize(reference, capture, channel)
          @reference, @capture, @channel = reference, capture, channel
          @epoch = SecureRandom.hex(16).freeze
          @capture.process.retain
        end

        def close
          @channel.close
          @capture.close unless @released
          @released = true
        end
      end

      class Prepared
        attr_reader :reference, :run_id, :process_generation, :receipt, :completion

        def initialize(registry, enrollment, digest, listener, path)
          @registry, @enrollment, @digest, @listener, @path = registry, enrollment, digest.freeze, listener, path
          @reference = enrollment.reference
          @process_generation = enrollment.capture.process.generation
          @run_id, @token = SecureRandom.hex(16).freeze, SecureRandom.hex(16).freeze
          @authorization = SecureRandom.hex(32).freeze
          @identity = enrollment.capture.process.retain
        end

        def prepare(budget)
          @identity.ensure_live!
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget.options.fetch(:timeout)
          @sent = true
          @enrollment.channel.write("P #{@run_id} #{@token} #{[@path].pack('m0')} #{deadline} #{@digest}", budget)
          @channel = Channel.new(@registry.__send__(:accept_socket, @listener, budget))
          response = @channel.read(budget).split(' ')
          expected = [@run_id, @token, @digest, @identity.pid.to_s]
          unless response.drop(1) == expected && %w[READY REFUSED].include?(response.first)
            raise ProtocolError.new('prepared helper identity is invalid', phase: :admission)
          end
          raise UnsupportedFeatureError.new('shell editor is not idle and empty', phase: :admission) if response.first == 'REFUSED'

          @identity.ensure_live!
          self
        end

        def authorized?
          !!@receipt
        end

        def authorize(timeout: 0.5, cancel: nil)
          raise ClosedError.new('prepared authorization is single use', phase: :admission) if @attempted || @closed

          @attempted = true
          @registry.__send__(:perform, timeout, cancel) do |budget|
          @identity.ensure_live!
          @registry.__send__(:guard, @reference, @identity, budget, @authorization) { @grant_attempted = true }
          @receipt = {'state' => 'authorized', 'run_id' => @run_id, 'script_digest' => @digest,
            'server_generation' => @reference.binding_key, 'pane_id' => @reference.id,
            'enrollment_generation' => @enrollment.epoch, 'process_generation' => @process_generation}.transform_values(&:freeze).freeze
          @identity.ensure_live!
          @channel.write("GRANT #{@run_id} #{@token} #{@digest}", budget)
          expected = "AUTHORIZED #{@run_id} #{@token} #{@digest}"
          raise ProtocolError.new('prepared helper acknowledgement is invalid', phase: :read, delivery: :possibly_sent) unless @channel.read(budget) == expected

          @receipt
          end
        end

        def grant_attempted?
          !!@grant_attempted
        end

        def execute(script, stdout_limit:, stderr_limit:, timeout:, cancel: nil)
          raise ClosedError.new('prepared script is not authorized or has already been sent', phase: :admission) unless @receipt && !@executed && !@closed

          @executed = true
          @registry.__send__(:perform, timeout, cancel) do |operation|
            @channel.write("SCRIPT #{@run_id} #{@token} #{@digest} #{script.bytesize} #{stdout_limit} #{stderr_limit}", operation)
            @channel.write_bytes(script, operation)
            response = @channel.read(operation).split(' ')
            unless response[1, 3] == [@run_id, @token, @digest]
              raise ProtocolError.new('script response identity is invalid', phase: :read, delivery: :possibly_sent)
            end
            if response.first == 'ERROR' && response.length == 6
              klass = {'capacity' => CapacityError, 'deadline' => DeadlineExceeded, 'cancelled' => Cancelled,
                'protocol' => ProtocolError, 'unknown' => OutcomeUnknown}.fetch(response[4], OutcomeUnknown)
              cleanup = response[5] == 'clean' ? [] : ['authored child retirement was incomplete']
              raise klass.new('authored script did not establish completion', phase: :read, delivery: :possibly_sent, cleanup_errors: cleanup)
            end
            unless response.length == 8 && response.first == 'RESULT' && %w[EXIT SIGNAL].include?(response[4]) && response[5, 3].all? { |value| /\A\d{1,9}\z/.match?(value) }
              raise ProtocolError.new('script completion frame is invalid', phase: :read, delivery: :possibly_sent)
            end
            status, out_length, err_length = response[5, 3].map(&:to_i)
            if out_length > stdout_limit || err_length > stderr_limit || status > 255 || (response[4] == 'SIGNAL' && status.zero?)
              raise ProtocolError.new('script completion exceeds its limits', phase: :read, delivery: :possibly_sent)
            end
            @completion = {'state' => response[4] == 'EXIT' ? 'exited' : 'signaled',
              'exit_status' => response[4] == 'EXIT' ? status : nil, 'signal' => response[4] == 'SIGNAL' ? status : nil}.freeze
            Result.new(stdout: @channel.read_bytes(out_length, operation), stderr: @channel.read_bytes(err_length, operation),
              exit_status: response[4] == 'EXIT' ? status : nil, signal: response[4] == 'SIGNAL' ? status : nil, receipt: @receipt)
          end
        end

        def close(timeout: 0.4)
          return if @closed

          @channel&.close
          @listener.close unless @listener.closed?
          File.unlink(@path) if File.exist?(@path)
          if @sent && !@channel
            @registry.__send__(:discard, @enrollment)
            @done = true
          end
          if @sent && !@done
            response = @enrollment.channel.read(@registry.__send__(:budget, timeout, nil)).split(' ')
            unless response.length == 3 && response[0, 2] == ['DONE', @run_id] && /\A\d+\z/.match?(response[2])
              raise ProtocolError.new('prepared helper retirement is invalid', phase: :retire)
            end
            @done = true
          end
          @identity.close unless @released
          @released = true
          @closed = true
          @enrollment.prepared = nil
          @registry.__send__(:release, self)
          nil
        end
      end

      def initialize(server:, parent:, max_enrollments: 8)
        unless server.is_a?(LibTmux::Async::Server) && parent.is_a?(::Async::Task) && !parent.finished? && parent.root.equal?(Fiber.scheduler)
          raise ArgumentError, 'enrollment requires an application-owned Async server and live parent task'
        end
        raise ArgumentError, 'enrollment capacity must be positive' unless max_enrollments.is_a?(Integer) && max_enrollments.positive?

        @server, @parent, @capacity = server, parent, max_enrollments
        @thread, @pid, @scheduler = Thread.current, Process.pid, Fiber.scheduler
        @pending, @enrollments, @prepared = [], {}, []
        @reservations, @retiring, @accepting = {}, [], {}
        @calls, @runs, @watchers, @changed = {}, {}, [], ::Async::Notification.new
        @directory = Dir.mktmpdir('libtmux-ruby-enrollment-')
      end

      def inspect
        "#<#{self.class} closed=#{!!@closed}>"
      end

      def run(reference, script:, timeout: 0.5, cancel: nil, stdout_limit: 65_536, stderr_limit: 65_536)
        ensure_open
        unless script.is_a?(String) && script.bytesize <= 65_536 && !script.include?("\0")
          raise ArgumentError, 'script must contain at most 65536 bytes without NUL'
        end
        unless [stdout_limit, stderr_limit].all? { |value| value.is_a?(Integer) && value.between?(0, 262_144) }
          raise ArgumentError, 'script output limits must be integers between 0 and 262144'
        end
        script = script.b.freeze
        run_owner = ::Async::Task.current
        raise CapacityError.new('authored run capacity is full', phase: :admission) if @runs.length >= @capacity || @runs.key?(run_owner)

        @runs[run_owner] = true
        owned_run = true
        operation = budget(timeout, cancel)
        prepared = prepare(reference, script_digest: Digest::SHA256.hexdigest(script), **operation.options)
        prepared.authorize(**operation.options)
        prepared.execute(script, stdout_limit: stdout_limit, stderr_limit: stderr_limit, **operation.options)
      rescue Exception => error
        error.extend(RunReceipt)
        error.instance_variable_set(:@run_delivery, prepared&.grant_attempted? ? error.respond_to?(:delivery) && error.delivery || :possibly_sent : :not_sent)
        if prepared&.receipt
          error.instance_variable_set(:@run_receipt, prepared.receipt)
          error.instance_variable_set(:@run_completion, prepared.completion)
        end
        raise
      ensure
        begin
          if prepared
            primary = $!
            begin
              prepared.close
            rescue Exception => cleanup
              if primary
                ProcessIdentity.attach_cleanup(primary, ["authored helper retirement failed (#{cleanup.class})"])
              else
                cleanup.extend(RunReceipt)
                cleanup.instance_variable_set(:@run_receipt, prepared.receipt)
                cleanup.instance_variable_set(:@run_completion, prepared.completion)
                cleanup.instance_variable_set(:@run_delivery, prepared.completion ? :observed : :possibly_sent)
                raise
              end
            end
          end
        ensure
          if owned_run
            @runs.delete(run_owner)
            @changed.signal
          end
        end
      end

      def invite(reference, timeout: 0.5, cancel: nil, expires_in: 60)
        ensure_open
        unless expires_in.is_a?(Numeric) && expires_in.finite? && expires_in.positive? && expires_in <= 300
          raise ArgumentError, 'shell invitation lifetime must be positive and at most 300 seconds'
        end
        perform(timeout, cancel) do |operation|
        @server.__send__(:target, reference, :pane)
        @pending.dup.each do |pending|
          next if @accepting.key?(pending) || clock < pending.expires_at

          retire([pending])
          @pending.delete(pending)
          @reservations.delete(pending.reference)
        end
        if @reservations.length + @enrollments.length >= @capacity || @reservations.key?(reference) || @enrollments.key?(reference)
          raise CapacityError.new('shell enrollment capacity is full', phase: :admission)
        end
        reservation = Object.new
        @reservations[reference] = reservation
        token = Internal::Cancellation.new
        observer = Observation.new(server: @server, arguments: {'target' => wire(reference), 'track' => true,
          'max_lines' => 1, 'max_bytes' => 1}, timeout: operation.options.fetch(:timeout), cancel: cancel || token, max_snapshot_bytes: 1 << 20)
        _result, capture = observer.capture(expires: Float::INFINITY)
        path = File.join(@directory, SecureRandom.hex(12))
        socket = SocketLease.new(path)
        @retiring << socket
        listener = socket.bind
        invitation = Invitation.new(reference: reference, capture: capture, listener: listener, path: path, expires_at: clock + expires_in)
        @pending << invitation
        @retiring.delete(socket)
        invitation
      ensure
        begin
          retire([observer, token, *(invitation ? [] : [socket, capture])].compact, primary: $!)
        ensure
          @reservations.delete(reference) if reservation && !invitation && @reservations[reference].equal?(reservation)
        end
        end
      end

      def accept(invitation, timeout: nil, cancel: nil)
        ensure_open
        raise ArgumentError, 'invitation is not pending in this registry' unless @pending.include?(invitation)
        raise CapacityError.new('shell invitation already has an acceptor', phase: :admission) if @accepting.key?(invitation)

        @accepting[invitation] = true
        accepted_slot = true
        channel = enrollment = nil
        acknowledged = false
        remaining = invitation.expires_at - clock
        timeout = timeout ? [timeout, remaining].min : remaining
        perform(timeout, cancel) do |operation|
          channel = Channel.new(accept_socket(invitation.listener, operation))
          identity = invitation.capture.process
          identity.ensure_live!
          peer_pid = if RUBY_PLATFORM.include?('darwin')
            channel.io.getsockopt(0, 0x002).int # SOL_LOCAL / LOCAL_PEERPID; generation remains the native lease.
          else
            channel.io.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).data.unpack1('i')
          end
          hello = channel.read(operation).split(' ')
          unless peer_pid == identity.pid && hello.length == 4 && hello[0, 2] == ['ZLE1', invitation.token] &&
              /\A5\.9(?:\.\d+)?\z/.match?(hello[2]) && hello[3] == invitation.reference.id
            raise UnsupportedFeatureError.new('shell enrollment identity or profile is unsupported', phase: :admission)
          end
          guard(invitation.reference, identity, operation)
          enrollment = Enrollment.new(invitation.reference, invitation.capture, channel)
          @enrollments[enrollment.reference] = enrollment
          retire([invitation])
          channel.write_bytes('A', operation)
          acknowledged = true
          enrollment
        end
      ensure
        if accepted_slot
          begin
            unless acknowledged
              @enrollments.delete(invitation.reference) if @enrollments[invitation.reference].equal?(enrollment)
              retire([enrollment || channel, invitation].compact, primary: $!)
            end
          ensure
            @accepting.delete(invitation)
            @pending.delete(invitation)
            @reservations.delete(invitation.reference)
          end
        end
      end

      def prepare(reference, script_digest:, timeout: 0.5, cancel: nil)
        ensure_open
        unless script_digest.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(script_digest)
          raise ArgumentError, 'script_digest must be a SHA256 hex digest'
        end
        enrollment = @enrollments[reference]
        raise UnsupportedFeatureError.new('pane has no enrolled shell', phase: :admission) unless enrollment
        raise CapacityError.new('shell already has an active preparation', phase: :admission) if enrollment.prepared

        perform(timeout, cancel) do |operation|
        raise CapacityError.new('shell already has an active preparation', phase: :admission) if enrollment.prepared
        path = File.join(@directory, SecureRandom.hex(12))
        socket = SocketLease.new(path)
        @retiring << socket
        listener = socket.bind
        prepared = Prepared.new(self, enrollment, script_digest.dup, listener, path)
        enrollment.prepared = prepared
        @prepared << prepared
        @retiring.delete(socket)
        prepared.prepare(operation)
      rescue Exception => error
        begin
          prepared ? prepared.close : retire([socket].compact, primary: error)
        rescue Exception => cleanup
          ProcessIdentity.attach_cleanup(error, ["prepared helper retirement failed (#{cleanup.class})"])
        end
        raise
        end
      end

      def close(timeout: 0.5)
        ensure_owner
        unless timeout.is_a?(Numeric) && timeout.finite? && timeout.between?(0, 0.5)
          raise ArgumentError, 'enrollment cleanup timeout must be between 0 and 0.5 seconds'
        end
        if @calls.key?(::Async::Task.current) || @runs.key?(::Async::Task.current)
          raise ClosedError.new('cannot close enrollment from an active request', phase: :retire)
        end

        @closed = true
        deadline = clock + timeout
        errors, interrupted = [], nil
        attempt = lambda do |label, &work|
          begin
            work.call
          rescue ::Async::Cancel => error
            interrupted ||= error
            retry if clock < deadline
            errors << "#{label} remains pending"
          rescue Exception => error
            errors << "#{label} failed (#{error.class})"
          end
        end
        (@calls.keys + @runs.keys).uniq.each do |task|
          attempt.call('request cancellation') { task.cancel unless task.finished? }
        end
        until (@calls.empty? && @runs.empty?) || clock >= deadline
          begin
            ::Async::Task.current.with_timeout(deadline - clock) { @changed.wait }
          rescue ::Async::Cancel => error
            interrupted ||= error
          rescue ::Async::TimeoutError
            break
          end
        end
        if @calls.empty? && @runs.empty?
          @watchers.dup.each do |watcher|
            attempt.call('cancellation watcher retirement') do
              watcher.cancel unless watcher.finished?
              watcher.wait(timeout: [deadline - clock, 0].max) unless watcher.finished?
              @watchers.delete(watcher) if watcher.finished?
            end
          end
          @prepared.dup.each do |prepared|
            attempt.call('prepared shell retirement') { prepared.close(timeout: [deadline - clock, 0].max) }
          end
          @pending.dup.each do |invitation|
            attempt.call('invitation retirement') do
              invitation.close
              @pending.delete(invitation)
              @reservations.delete(invitation.reference)
            end
          end
          @enrollments.dup.each do |reference, enrollment|
            next if enrollment.prepared

            attempt.call('enrollment retirement') do
              enrollment.close
              @enrollments.delete(reference)
            end
          end
          @retiring.dup.each do |resource|
            attempt.call('shell resource retirement') do
              resource.is_a?(Observation) ? resource.close(timeout: [deadline - clock, 0].max) : resource.close
              @retiring.delete(resource)
            end
          end
        else
          errors << 'admitted shell requests remain active'
        end
        attempt.call('enrollment directory retirement') { Dir.rmdir(@directory) if Dir.exist?(@directory) } if errors.empty?
        if interrupted
          ProcessIdentity.attach_cleanup(interrupted, errors) unless errors.empty?
          raise interrupted
        end
        raise TransportError.new('shell enrollment cleanup remains pending', phase: :retire, cleanup_errors: errors) unless errors.empty?

        nil
      end

      private

      def retire(resources, primary: nil)
        failure = primary
        resources.each do |resource|
          begin
            resource.close
            @retiring.delete(resource)
          rescue Exception => error
            @retiring << resource unless @retiring.include?(resource)
            ProcessIdentity.attach_cleanup(failure, ["shell resource cleanup failed (#{error.class})"]) if failure
            failure ||= error
          end
        end
        raise failure if failure && !primary
      end

      def perform(timeout, cancel)
        ensure_open
        owner = ::Async::Task.current
        if @calls.length >= @capacity * 2 || @watchers.length >= @capacity * 2
          raise CapacityError.new('shell protocol request capacity is full', phase: :admission)
        end
        raise ClosedError.new('nested shell protocol request', phase: :admission) if @calls.key?(owner)
        raise Cancelled.new('shell protocol request cancelled', phase: :admission) if cancel&.cancelled?

        @calls[owner] = true
        armed = true
        watcher = failure = result = nil
        begin
          watcher = if cancel
            ::Async::Task.new(@parent) do
              Fiber.scheduler.io_wait(cancel.reader, IO::READABLE) unless cancel.cancelled?
              owner.cancel if armed && cancel.cancelled?
            end
          end
          @watchers << watcher if watcher
          watcher&.run
          result = yield budget(timeout, cancel)
        rescue ::Async::Cancel => error
          failure = (@closed || cancel&.cancelled?) ? Cancelled.new('shell protocol request cancelled', phase: :admission, delivery: :possibly_sent) : error
        rescue Exception => error
          failure = error
        ensure
          armed = false
          deadline = clock + 0.4
          if watcher
            begin
              watcher.cancel unless watcher.finished?
              watcher.wait(timeout: [deadline - clock, 0].max) unless watcher.finished?
            rescue ::Async::Cancel => error
              failure ||= error
              retry if clock < deadline
            rescue Exception => error
              ProcessIdentity.attach_cleanup(failure, ["cancellation watcher cleanup failed (#{error.class})"]) if failure
              failure ||= TransportError.new('cancellation watcher cleanup remains pending', phase: :retire)
            ensure
              @watchers.delete(watcher) if watcher.finished?
            end
          end
          @calls.delete(owner)
          @changed.signal
        end
        raise failure if failure

        result
      end

      def discard(enrollment)
        enrollment.close
        @enrollments.delete(enrollment.reference)
      end

      def wire(ref)
        {'generation' => ref.binding_key, 'kind' => 'pane', 'id' => ref.id}
      end

      def release(prepared)
        @prepared.delete(prepared)
      end

      def budget(timeout, cancel)
        ensure_owner
        @server.__send__(:operation_budget, timeout, cancel)
      end

      def accept_socket(listener, operation)
        loop do
          remaining = operation.options.fetch(:timeout)
          socket = listener.accept_nonblock(exception: false)
          return socket unless socket == :wait_readable

          Fiber.scheduler.io_wait(listener, IO::READABLE, remaining)
        end
      end

      def guard(reference, identity, operation, nonce = nil)
        identity.ensure_live!
        names = @server.__send__(:builtin_spellings, 'if-shell', 'wait-for', budget: operation)
        predicate = "\#{&&:\#{==:\#{pane_id},#{reference.id}},\#{&&:\#{==:\#{pane_pid},#{identity.pid}},\#{&&:\#{==:\#{pane_dead_status},},\#{==:\#{pane_dead_signal},}}}}"
        branch = if nonce
          [@server.__send__(:tmux_command, [names.fetch('wait-for'), '-S', nonce]),
            @server.__send__(:tmux_command, [names.fetch('wait-for'), nonce])].join(' ; ')
        else
          ''
        end
        failure = @server.__send__(:tmux_command, [names.fetch('wait-for')])
        yield if block_given?
        @server.__send__(:execute_typed, [names.fetch('if-shell'), '-F', '-t', reference.id, predicate, branch, failure], **operation.options)
      rescue CommandError => error
        raise TargetNotFoundError.new('enrolled shell no longer belongs to the pane', phase: :admission, delivery: :not_sent), cause: nil
      end

      def ensure_owner
        unless Process.pid == @pid && Thread.current.equal?(@thread) && Fiber.scheduler.equal?(@scheduler)
          raise ClosedError.new('shell enrollment belongs to another scheduler', phase: :admission)
        end
      end

      def ensure_open
        ensure_owner
        raise ClosedError.new('shell enrollment is closed', phase: :admission) if @closed
        raise CapacityError.new('shell resource retirement remains pending', phase: :admission) unless @retiring.empty?
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
    private_constant :EnrollmentRegistry
  end
end
