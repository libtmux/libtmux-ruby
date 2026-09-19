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

        @scope.__send__(:execute, @pin.command_prefix + argv, input: input, timeout: timeout, cancel: cancel)
      end

      def close
        @scope.close
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

      private

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
