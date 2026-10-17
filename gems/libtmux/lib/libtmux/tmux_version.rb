# frozen_string_literal: true

require "libtmux/errors"
require "securerandom"

module LibTmux
  module Internal
    # Version check for the tmux daemon a server handle is bound to.
    #
    # The connected daemon decides support, not the configured client. A
    # release is read once through the retained route and every dispatch is
    # then fenced against that exact text.
    module TmuxVersion
      MINIMUM = "3.3a"
      PATTERN = /\A(?<next>next-)?(?<major>\d+)\.(?<minor>\d+)(?<patch>[a-z]?)(?<candidate>-rc\d*)?\z/
      # Abbreviations resolve to if-shell and run-shell, but a command-alias
      # entry named for the full command does not reach them.
      FENCE_COMMAND = "if-shel"
      PROBE_COMMAND = "run-shel"
      ABSENT = /no server running|error connecting to .*\((?:No such file or directory|Connection refused)\)/

      # `key` orders releases; a development build or release candidate ranks
      # below the release it names.
      Release = Data.define(:text, :key) do
        include Comparable

        def stable?
          key.last == 1
        end

        def <=>(other)
          key <=> other.key if other.is_a?(Release)
        end
      end

      module_function

      def parse(value)
        match = value.is_a?(String) && PATTERN.match(value)
        unless match
          raise UnsupportedFeatureError.new("tmux version is unrecognized; tmux #{MINIMUM} or newer is required",
            phase: :admission)
        end
        patch = match[:patch].each_byte.reduce(0) { |number, byte| number * 26 + byte - 96 }
        stable = !match[:next] && !match[:candidate]
        Release.new(text: value.dup.freeze, key: [match[:major].to_i, match[:minor].to_i, patch, stable ? 1 : 0].freeze)
      end

      def require_supported(value, minimum: MINIMUM)
        release = parse(value)
        if (release <=> parse(minimum)).negative?
          raise UnsupportedFeatureError.new("tmux #{minimum} or newer is required (connected version #{release.text})",
            phase: :admission)
        end
        release
      end

      # Reads the daemon behind +prefix+. The block runs the argv and returns a
      # CommandResult. Unlike display-message, run-shell -C fires no after-*
      # hook and no command-error hook: tmux parses the expanded string after
      # the command returned, so the private unknown command it reports has no
      # effect and the version travels in the error text.
      def connected(prefix)
        marker = "libtmux-version-#{SecureRandom.hex(16)}-"
        result = yield(prefix + [PROBE_COMMAND, "-C", marker + '#{version}'])
        stderr = result.stderr.dup.force_encoding(Encoding::UTF_8)
        if !result.success? && result.stdout.empty? && (match = /\Aunknown command: #{Regexp.escape(marker)}([^\n]+)\n\z/.match(stderr))
          return require_supported(match[1])
        end
        if ABSENT.match?(stderr)
          raise TargetNotFoundError.new("no tmux server is running at the selected endpoint", phase: :admission)
        end

        raise CommandError.new("tmux did not report a daemon version", result: result, phase: :admission, delivery: :not_sent)
      rescue Error => error
        raise not_sent(error), cause: nil
      end

      # Reads the executable that would start a new daemon. tmux 3.3a prints
      # its own file name where later releases print "tmux".
      def executable(path)
        result = yield([path, "-V"])
        unless result.success?
          raise CommandError.new("tmux did not report its version", result: result, phase: :admission, delivery: :not_sent)
        end

        names = ["tmux", File.basename(path)].uniq.map { |name| Regexp.escape(name.b) }.join("|")
        match = /\A(?:#{names}) ([^\n]+)\n?\z/n.match(result.stdout)
        require_supported(match && match[1])
      rescue Error => error
        raise not_sent(error), cause: nil
      end

      # Leading commands for one dispatch. A daemon that no longer reports
      # +release+ fails the if-shell condition and reaches the private marker,
      # which tmux rejects before the commands that follow.
      def fence(release)
        marker = "libtmux-version-#{SecureRandom.hex(16)}"
        [[FENCE_COMMAND, "-F", "\#{==:\#{version},#{release.text}}", "", marker, ";"], marker]
      end

      def check_fence(result, marker, release)
        return result unless result.stderr.b.each_line.any? { |line| line.chomp == "unknown command: #{marker}".b }

        raise UnsupportedFeatureError.new("the tmux daemon no longer reports #{release.text}; reopen the server",
          phase: :admission, delivery: :not_sent)
      end

      def not_sent(error)
        details = {delivery: :not_sent, phase: :admission, pid: error.pid, cleanup_errors: error.cleanup_errors}
        return error.class.new(error.message, result: error.result, **details) if error.is_a?(CommandError)

        error.class.new(error.message, **details)
      end
    end
  end
end
