# frozen_string_literal: true

require "fiddle"
require "libtmux/errors"

module LibTmux
  module Internal
    class ProcessWait
      P_PID = 1
      WNOHANG = 0x00000001
      WEXITED = 0x00000004
      private_constant :P_PID, :WNOHANG, :WEXITED

      def initialize
        unless Fiddle::SIZEOF_INT == 4
          raise UnsupportedFeatureError.new("native process waiting requires a 32-bit C int", phase: :admission)
        end

        # Native wait.h values differ: Linux WNOWAIT=0x01000000, Darwin=0x20.
        case RUBY_PLATFORM
        when /linux/
          @options = WEXITED | 0x01000000
          @information_size = 128 # Linux siginfo_t has a fixed 128-byte ABI.
        when /darwin/
          @options = WEXITED | 0x00000020
          @information_size = 6 * Fiddle::SIZEOF_INT + 2 * Fiddle::SIZEOF_VOIDP + 8 * Fiddle::SIZEOF_LONG
        else
          raise UnsupportedFeatureError.new("native process waiting is unavailable on this platform", phase: :admission)
        end

        @waitid = Fiddle::Function.new(Fiddle::Handle::DEFAULT["waitid"],
          [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_INT, need_gvl: false)
        verify_available
      rescue Fiddle::DLError
        raise UnsupportedFeatureError.new("native waitid is unavailable", phase: :admission), cause: nil
      end

      def observe(pid)
        raise ArgumentError, "child PID must be a positive integer" unless pid.is_a?(Integer) && pid.positive?

        Fiddle::Pointer.malloc(@information_size, Fiddle::RUBY_FREE) do |information|
          loop do
            return if @waitid.call(P_PID, pid, information, @options).zero?

            error = Fiddle.last_error
            next if error == Errno::EINTR::Errno

            raise SystemCallError.new("waitid", error)
          end
        end
      end

      private

      def verify_available
        Fiddle::Pointer.malloc(@information_size, Fiddle::RUBY_FREE) do |information|
          # A process cannot be its own child. Probe flags before owning a client.
          status = @waitid.call(P_PID, Process.pid, information, @options | WNOHANG)
          return if status == -1 && Fiddle.last_error == Errno::ECHILD::Errno
        end
        raise UnsupportedFeatureError.new("native non-reaping process observation is unavailable", phase: :admission)
      end
    end
  end
end
