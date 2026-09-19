# frozen_string_literal: true

module LibTmux
  # Raw bytes remain available even when a caller requests a typed conversion.
  class OptionValue
    attr_reader :name, :index, :raw

    def initialize(name:, index:, raw:, inherited:, array:, present:)
      @name, @raw = name.dup.freeze, raw.dup.freeze
      @index, @inherited, @array, @present = index, inherited, array, present
      freeze
    end
    private_class_method :new

    def inherited?
      @inherited
    end

    def array?
      @array
    end

    def present?
      @present
    end

    def as(type)
      case type
      when :bytes then raw
      when :string
        text = raw.dup.force_encoding(Encoding::UTF_8)
        raise FieldDecodeError.new("option is not valid UTF-8", phase: :decode, delivery: :observed) unless text.valid_encoding?

        text.freeze
      when :integer
        raise FieldDecodeError.new("option is not an integer", phase: :decode, delivery: :observed) unless raw.match?(/\A-?\d+\z/)

        Integer(raw, 10)
      when :boolean
        return true if ["on", "1"].include?(raw)
        return false if ["off", "0"].include?(raw)

        raise FieldDecodeError.new("option is not a boolean", phase: :decode, delivery: :observed)
      else raise ArgumentError, "type must be :bytes, :string, :integer or :boolean"
      end
    end
  end

  # Explicit acquisition and mutation at one option scope.
  class Options
    def initialize(server, ref: nil, scope: nil)
      @server, @ref, @scope = server, ref, scope
      freeze
    end
    private_class_method :new

    def list(name: nil, inherited: false, timeout: 5.0, cancel: nil)
      if inherited && is_a?(Hooks)
        raise UnsupportedFeatureError.new("inherited hook acquisition is not implemented", phase: :admission)
      end
      command = is_a?(Hooks) ? "show-hooks" : "show-options"
      args = [command, *scope_flags]
      args << "-A" if inherited && !is_a?(Hooks)
      args.concat(["--", option_name(name)]) if name
      result = @server.__send__(:execute_typed, args, timeout: timeout, cancel: cancel)
      result.stdout.lines.map do |line|
        match = /\A([^\s\[\]*]+)(?:\[(\d+)\])?(\*)?(?: (.*))?\n\z/n.match(line)
        raise ProtocolError.new("malformed escaped option record", phase: :decode, delivery: :observed) unless match

        value = match[4]
        raw = is_a?(Hooks) ? (value || "".b) : decode_escaped(value || "".b)
        OptionValue.__send__(:new, name: match[1], index: match[2] && Integer(match[2], 10), raw: raw,
          inherited: !match[3].nil?, array: !match[2].nil? || value.nil?, present: !value.nil?)
      end.freeze
    end

    def get(name, index: nil, inherited: true, timeout: 5.0, cancel: nil)
      unless index.nil? || (index.is_a?(Integer) && index >= 0)
        raise ArgumentError, "index must be a nonnegative Integer"
      end
      # tmux prints a nonexistent requested index as an empty string. Acquire
      # the array once so absent indexes remain distinct from present empties.
      values = list(name: name, inherited: inherited, timeout: timeout, cancel: cancel)
      values = values.select { |value| value.index == index } unless index.nil?
      if values.empty?
        raise NoMatchError.new("option is absent at the requested scope", phase: :decode, delivery: :observed)
      end
      unless values.length == 1
        raise MultipleMatchesError.new("option has multiple array entries; provide an index", phase: :decode, delivery: :observed)
      end

      values.first
    end

    def set(name, value, index: nil, append: false, timeout: 5.0, cancel: nil)
      value = case value
      when true then "on"
      when false then "off"
      when Integer then value.to_s
      when String then value
      else raise ArgumentError, "option value must be String, Integer or boolean"
      end
      mutate("set-option", name, value, index: index, append: append, timeout: timeout, cancel: cancel)
    end

    def unset(name, index: nil, timeout: 5.0, cancel: nil)
      command = is_a?(Hooks) ? "set-hook" : "set-option"
      @server.__send__(:execute_typed, [command, *scope_flags, "-u", "--", option_name(indexed_name(name, index))], timeout: timeout, cancel: cancel)
    end

    private

    def scope_flags
      if @ref
        flags = {session: [], window: ["-w"], pane: ["-p"]}.fetch(@ref.kind)
        [*flags, "-t", @server.__send__(:target, @ref, @ref.kind)]
      else
        {server: ["-s"], session: ["-g"], window: ["-g", "-w"]}.fetch(@scope) do
          raise ArgumentError, "scope must be :server, :session or :window"
        end
      end
    end

    def option_name(name)
      unless name.is_a?(String) && name.match?(/\A[^\s\0]+\z/)
        raise ArgumentError, "option names cannot contain whitespace or NUL"
      end
      @server.__send__(:literal_name, name)
    end

    def indexed_name(name, index)
      return name if index.nil?
      raise ArgumentError, "index must be a nonnegative Integer" unless index.is_a?(Integer) && index >= 0

      "#{name}[#{index}]"
    end

    def mutate(command, name, value, index:, append:, timeout:, cancel:)
      args = [command, *scope_flags]
      args << "-a" if append
      @server.__send__(:execute_typed, [*args, "--", option_name(indexed_name(name, index)), value], timeout: timeout, cancel: cancel)
    end

    # show-options uses args_escape (VIS_OCTAL|VIS_CSTYLE), not shell escaping.
    def decode_escaped(value)
      if value.start_with?("'", '"')
        unless value.end_with?(value.byteslice(0, 1)) && value.bytesize >= 2
          raise ProtocolError.new("unterminated escaped option value", phase: :decode, delivery: :observed)
        end
        value = value.byteslice(1, value.bytesize - 2)
      end
      escapes = {"a" => "\a", "b" => "\b", "t" => "\t", "n" => "\n", "v" => "\v", "f" => "\f", "r" => "\r", "s" => " ", "E" => "\e"}
      value.gsub(/\\([0-7]{3}|.)/n) do
        escaped = Regexp.last_match(1)
        if escaped.match?(/\A[0-7]{3}\z/)
          escaped.to_i(8).chr(Encoding::BINARY)
        else
          escapes.fetch(escaped, escaped)
        end
      end
    end
  end

  # Hook values are executable tmux command strings, never literal data.
  class Hooks < Options
    def get(name, index: nil, inherited: false, timeout: 5.0, cancel: nil)
      super
    end

    def set(name, command:, index: nil, append: false, timeout: 5.0, cancel: nil)
      raise ArgumentError, "command must be a String" unless command.is_a?(String)

      mutate("set-hook", name, command, index: index, append: append, timeout: timeout, cancel: cancel)
    end

    def run(name, timeout: 5.0, cancel: nil)
      @server.__send__(:execute_typed, ["set-hook", *scope_flags, "-R", "--", option_name(name)], timeout: timeout, cancel: cancel)
    end
  end
end
