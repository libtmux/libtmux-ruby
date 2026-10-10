# frozen_string_literal: true

module LibTmux
  module Async
    class Server < LibTmux::Server
      def initialize(scope, source)
        raise ArgumentError, "server must be a bound LibTmux::Server" unless source.is_a?(LibTmux::Server)

        @scope, @source = scope, source
        @mutex = Mutex.new
        source.__send__(:with_bound_endpoint) { |endpoint, pin| @endpoint, @pin = endpoint, pin }
      end

      def run(argv, input: "".b, timeout: 5.0, cancel: nil)
        ensure_owner
        ensure_open
        validate_argv(argv)
        raise ArgumentError, "raw commands cannot override endpoint flags" if argv.first.start_with?("-")

        @scope.__send__(:execute, @pin.command_prefix + argv, input: input, timeout: timeout, cancel: cancel, env: @endpoint.environment)
      end

      def close
        @scope.close
      end

      # Scope counters remain readable after this facade closes its scope.
      def diagnostics
        @scope.diagnostics
      end

      def open_control(session:, **options)
        session_id = target(session, :session)
        control = @scope.__send__(:open_control, binding: @pin, session_id: session_id, **options)
        return control unless block_given?

        failure = result = nil
        begin
          result = yield control
        rescue Exception => error
          failure = error
        ensure
          begin
            control.close
          rescue Exception => error
            details = ["Async control close failed (#{error.class})"]
            details.concat(error.cleanup_errors) if error.is_a?(Error)
            Async.__send__(:attach_cleanup, failure, details) if failure
            failure ||= error
          end
        end
        raise failure if failure

        result
      end

      def attach(**)
        raise UnsupportedFeatureError.new("interactive terminal attachment requires the blocking core facade", phase: :admission)
      end

      def self.start(**)
        raise UnsupportedFeatureError.new("create an owned core server before opening its Async scope", phase: :admission)
      end

      def self.find_or_create(**)
        raise UnsupportedFeatureError.new("find or create a core server before opening its Async scope", phase: :admission)
      end

      def self.discover(**options)
        LibTmux::Server.discover(**options)
      end

      private

      # Core ownership retains the same pinned binding. Async cancellation waits
      # for receipt handoff; cleanup can still run after this scope was cancelled.
      def lifecycle_execute(program, names, budget)
        @source.__send__(:lifecycle_execute, program, names, budget)
      end

      def destroy_owned(receipt, timeout:)
        ::Async::Task.current.defer_cancel do
          @source.__send__(:destroy_owned, receipt, timeout: timeout)
        end
      end

      def acquire_owned(*arguments, **options, &block)
        owner = nil
        begin
          ::Async::Task.current.defer_cancel { owner = super(*arguments, **options, &nil) }
        rescue Exception => failure
          rollback_owner(owner, failure) if owner
          raise
        end
        block ? owner.use(&block) : owner
      end

      def adopt_resource(*arguments, **options, &block)
        owner = nil
        begin
          ::Async::Task.current.defer_cancel { owner = super(*arguments, **options, &nil) }
        rescue Exception => failure
          rollback_owner(owner, failure) if owner
          raise
        end
        block ? owner.use(&block) : owner
      end

      def find_or_create_entity(*arguments, **options)
        acquisition = nil
        begin
          ::Async::Task.current.defer_cancel { acquisition = super }
        rescue Exception => failure
          rollback_owner(acquisition.owner, failure) if acquisition&.owner
          raise
        end
        acquisition
      end

      def ensure_owner
        @scope.__send__(:ensure_owner)
      end

      def ensure_open
        @scope.__send__(:ensure_open)
        @source.__send__(:with_bound_endpoint) { nil }
      end
    end
  end
end
