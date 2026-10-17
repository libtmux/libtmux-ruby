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
      CONTROL_MINIMUM = "3.7"
      # The forms tmux has reported: X.Y, X.Y plus a patch letter, X.Y-rc and
      # X.Y-rcN candidates, and next-X.Y development builds. Anything else,
      # including master and openbsd-*, is not a release number.
      PATTERN = /\A(?:next-(?<next_major>\d+)\.(?<next_minor>\d+)|(?<major>\d+)\.(?<minor>\d+)(?:(?<patch>[a-z])|(?<candidate>-rc(?<number>\d*)))?)\z/
      # tmux resolves a command-alias entry by exact name before it resolves a
      # command, so the full names run-shell and if-shell can be hijacked by one
      # alias, as the existing link guards avoid with builtin_spellings. These
      # unique prefixes are out of reach of such an entry, and verify_fence
      # proves at the version check that the fence still rejects its marker, so an alias
      # named for a prefix, or a future command sharing it, refuses the server
      # instead of silently disabling the fence.
      FENCE_COMMAND = "if-shel"
      PROBE_COMMAND = "run-shel"
      ABSENT = /no server running|error connecting to .*\((?:No such file or directory|Connection refused)\)/

      # `key` orders releases; a development build or release candidate ranks
      # below the release it names.
      # `key` orders releases: major, minor, patch letter, then the build kind.
      # next-X.Y < X.Y-rc < X.Y-rcN < X.Y < X.Ya.
      STABLE = 1 << 20

      Release = Data.define(:text, :key) do
        include Comparable

        def stable?
          key.last == STABLE
        end

        def exactly?(major, minor)
          key == [major, minor, 0, STABLE]
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
        key = if match[:next_major]
          [match[:next_major].to_i, match[:next_minor].to_i, 0, 0]
        else
          patch = match[:patch] ? match[:patch].ord - 96 : 0
          kind = match[:candidate] ? 1 + match[:number].to_i : STABLE
          [match[:major].to_i, match[:minor].to_i, patch, kind]
        end
        Release.new(text: value.dup.freeze, key: key.freeze)
      end

      def require_supported(value, minimum: MINIMUM)
        release = parse(value)
        if (release <=> parse(minimum)).negative?
          raise UnsupportedFeatureError.new("tmux #{minimum} or newer is required (connected version #{release.text})",
            phase: :admission)
        end
        release
      end

      # Control clients crash tmux servers older than 3.7 while they attach.
      def require_control(release)
        raise UnsupportedFeatureError.new("control connections need a version-checked server", phase: :admission) unless release

        return release unless (release <=> parse(CONTROL_MINIMUM)).negative?

        raise UnsupportedFeatureError.new("control connections require tmux #{CONTROL_MINIMUM} or newer " \
          "(connected version #{release.text})", phase: :admission, delivery: :not_sent)
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

      # Reads daemon values through the probe's error text, which fires no
      # hook, unlike display-message. tmux reports only the first unparseable
      # word, so the fields expand to one comma-joined word.
      def identity_argv(fields)
        marker = "libtmux-identity-#{SecureRandom.hex(16)}-"
        [[PROBE_COMMAND, "-C", marker + fields.map { |field| "\#{#{field}}" }.join(",")], marker]
      end

      def parse_identity(result, marker, count)
        stderr = result.stderr.b
        match = /\Aunknown command: #{Regexp.escape(marker.b)}([^\n ]*)\n\z/n.match(stderr)
        values = match && match[1].split(",", -1)
        unless !result.success? && result.stdout.empty? && values && values.length == count
          raise ProtocolError.new("tmux did not report the requested identity", delivery: :observed, phase: :decode)
        end

        values.map(&:freeze)
      end

      # Leading commands for one dispatch. A daemon that no longer reports
      # +release+ fails the if-shell condition and reaches the private marker,
      # which tmux rejects before the commands that follow.
      def fence(release)
        marker = "libtmux-version-#{SecureRandom.hex(16)}"
        [[FENCE_COMMAND, "-F", "\#{==:\#{version},#{release.text}}", "", marker, ";"], marker]
      end

      # A server runs this once when it is checked. A true if-shell condition
      # runs a probe whose parse error names the marker, which shows that the
      # fence command and the probe command are the real ones, with no failing
      # command and so no hook.
      def fence_check_argv
        marker = "libtmux-fence-#{SecureRandom.hex(16)}"
        [[FENCE_COMMAND, "-F", "1", "#{PROBE_COMMAND} -C #{marker}"], marker]
      end

      def verify_fence(result, marker)
        return result if !result.success? && result.stdout.empty? && result.stderr.b == "unknown command: #{marker}\n".b

        raise UnsupportedFeatureError.new("a tmux command-alias or command shadows #{FENCE_COMMAND} or " \
          "#{PROBE_COMMAND}; remove it before opening a server", phase: :admission, delivery: :not_sent)
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
