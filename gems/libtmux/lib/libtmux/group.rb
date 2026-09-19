# frozen_string_literal: true

require_relative "server"

module LibTmux
  # Final client status cannot attribute a merged group result to individual steps.
  class GroupResult
    attr_reader :result, :steps

    def initialize(result, count)
      @result = result
      @steps = Array.new(count) { |index| {index: index, outcome: :unknown}.freeze }.freeze
      freeze
    end
    private_class_method :new

    def success?
      result.success?
    end

    def delivery
      result.delivery
    end

    def inspect
      "#<#{self.class} commands=#{steps.size} client_success=#{success?} delivery=#{delivery}>"
    end
  end

  class Server
    # One nontransactional tmux command group, with literal arguments per command.
    def run_group(commands, input: "".b, timeout: 5.0, cancel: nil)
      started = monotonic
      unless timeout.is_a?(Numeric) && timeout.finite?
        raise ArgumentError, "group timeout must be finite"
      end
      unless commands.is_a?(Array) && !commands.empty?
        raise ArgumentError, "commands must be a nonempty Array of argument Arrays"
      end
      if commands.length > 128
        raise CapacityError.new("command group exceeds 128 members", phase: :admission)
      end
      encoded = commands.map do |command|
        validate_argv(command)
        if command.first.start_with?("-")
          raise ArgumentError, "group members cannot override endpoint flags"
        end
        encode_arguments(command)
      end
      argv = []
      encoded.each_with_index do |command, index|
        argv << ";" unless index.zero?
        argv.concat(command)
      end
      result = run(argv, input: input, timeout: timeout - (monotonic - started), cancel: cancel)
      GroupResult.__send__(:new, result, encoded.length)
    end
  end
end
