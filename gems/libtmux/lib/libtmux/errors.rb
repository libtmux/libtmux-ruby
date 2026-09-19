# frozen_string_literal: true

module LibTmux
  class Error < StandardError
    attr_reader :delivery, :phase, :pid, :cleanup_errors, :entity, :path, :expected

    def initialize(message, delivery: :not_sent, phase: nil, pid: nil, cleanup_errors: [], entity: nil, path: nil, expected: nil)
      super(message)
      @delivery = delivery
      @phase = phase
      @pid = pid
      @cleanup_errors = cleanup_errors.dup.freeze
      @entity = entity
      @path = path&.dup&.freeze
      @expected = expected&.dup&.freeze
    end

    private

    def attach_cleanup_errors(errors)
      @cleanup_errors = (@cleanup_errors + errors).freeze
    end
  end

  class InvalidFilterError < Error
    def initialize(message = "invalid filter", entity: nil, path: "$", expected: nil, **details)
      super("#{message} at #{path}#{expected ? "; expected #{expected}" : ""}",
        entity: entity, path: path, expected: expected, **details)
    end
  end
  class IncompleteSnapshotError < Error; end
  class InconsistentSnapshotError < Error; end
  class NoMatchError < Error; end
  class MultipleMatchesError < Error; end
  class TargetNotFoundError < Error; end
  class FieldDecodeError < Error; end
  class UnsupportedFeatureError < Error; end
  class TransportError < Error; end
  class ProtocolError < Error; end
  class CapacityError < Error; end
  class DeadlineExceeded < Error; end
  class Cancelled < Error; end
  class OutcomeUnknown < Error; end
  class ClosedError < Error; end

  class CommandError < Error
    attr_reader :result

    def initialize(message = "tmux command failed", result: nil, **details)
      @result = result
      super(message, **{delivery: result&.delivery || :not_sent, pid: result&.pid}.merge(details))
    end
  end
end
