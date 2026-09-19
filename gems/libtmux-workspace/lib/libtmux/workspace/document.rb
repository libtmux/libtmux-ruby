# frozen_string_literal: true

module LibTmux
  class Workspace
    # JSON-compatible scalar rules avoid YAML object loading and implicit dates.
    class Document
      class YAMLHandler < Psych::Handler
        attr_reader :result

        def initialize(limits)
          @limits, @stack, @nodes, @documents = limits, [], 0, 0
        end

        def start_document(*)
          @documents += 1
          fail_input("exactly one YAML document") unless @documents == 1
        end

        def start_mapping(anchor, tag, *)
          container({}, anchor, tag)
        end

        def start_sequence(anchor, tag, *)
          container([], anchor, tag)
        end

        def end_mapping
          frame = @stack.pop
          fail_input("complete YAML mapping") unless frame[:key].nil?
        end

        def end_sequence
          @stack.pop
        end

        def scalar(value, anchor, tag, plain, quoted, *)
          fail_input("YAML without tags or anchors") if anchor || tag
          visit
          fail_input("bounded UTF-8 scalar") if value.bytesize > @limits.fetch(:max_string_bytes)
          decoded = if !plain || quoted
            value
          else
            case value
            when "true" then true
            when "false" then false
            when "null", "~", "" then nil
            when /\A-?(?:0|[1-9][0-9]*)\z/
              fail_input("bounded integer token") if value.bytesize > 20
              Integer(value, 10)
            when /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/
              fail_input("bounded scalar token") if value.bytesize > 32
              Float(value)
            else value
            end
          end
          append(decoded)
        end

        def alias(*)
          fail_input("YAML without aliases")
        end

        private

        def container(value, anchor, tag)
          fail_input("YAML without tags or anchors") if anchor || tag
          visit
          fail_input("bounded document depth") if @stack.length >= @limits.fetch(:max_depth)
          append(value)
          @stack << {value: value, key: nil}
        end

        def visit
          @nodes += 1
          fail_input("bounded document node count") if @nodes > @limits.fetch(:max_nodes)
        end

        def append(value)
          if @stack.empty?
            @result = value
          elsif @stack.last[:value].is_a?(Array)
            @stack.last[:value] << value
          else
            frame = @stack.last
            if frame[:key].nil?
              fail_input("string mapping keys") unless value.is_a?(String)
              fail_input("unique mapping keys") if frame[:value].key?(value)
              frame[:key] = value
            else
              frame[:value][frame[:key]] = value
              frame[:key] = nil
            end
          end
        end

        def fail_input(expected)
          raise ConfigError.new("invalid workspace document", path: "$", expected: expected)
        end
      end
      private_constant :YAMLHandler

      def initialize(limits)
        @limits = limits
      end

      def parse(bytes, format)
        unless bytes.is_a?(String) && bytes.bytesize <= @limits.fetch(:max_bytes)
          invalid("bounded document bytes")
        end
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        invalid("UTF-8 document") unless text.valid_encoding?
        value = case format
        when :json
          preflight_json(text)
          JSON.parse(text, max_nesting: @limits.fetch(:max_depth), allow_nan: false, allow_duplicate_key: false)
        when :yaml
          handler = YAMLHandler.new(@limits)
          Psych::Parser.new(handler).parse(text)
          handler.result
        else
          raise ArgumentError, "workspace format must be :json or :yaml"
        end
        validate_tree(value)
        value
      rescue JSON::ParserError, JSON::NestingError, Psych::Exception, EncodingError
        raise ConfigError.new("invalid workspace syntax", path: "$", expected: "data-only bounded JSON or YAML"), cause: nil
      end

      def validate_tree(value)
        @nodes = 0
        validate(value)
      end

      private

      # Bound allocation before JSON creates its object tree or large integers.
      def preflight_json(text)
        index, nodes, depth = 0, 0, 0
        while index < text.bytesize
          byte = text.getbyte(index)
          case byte
          when 34
            nodes += 1
            index += 1
            while index < text.bytesize
              current = text.getbyte(index)
              index += 1
              break if current == 34
              index += 1 if current == 92
            end
            index -= 1
          when 123, 91
            nodes += 1
            depth += 1
            invalid("bounded document depth") if depth > @limits.fetch(:max_depth)
          when 125, 93 then depth -= 1
          when 32, 9, 10, 13, 44, 58 then nil
          else
            nodes += 1
            first = index
            index += 1 while index < text.bytesize && ![32, 9, 10, 13, 44, 93, 125].include?(text.getbyte(index))
            invalid("bounded scalar token") if index - first > 32
            index -= 1
          end
          invalid("bounded document node count") if nodes > @limits.fetch(:max_nodes)
          index += 1
        end
      end

      def validate(value, depth = 0)
        @nodes += 1
        invalid("bounded document node count") if @nodes > @limits.fetch(:max_nodes)
        invalid("bounded document depth") if depth > @limits.fetch(:max_depth)
        case value
        when Hash
          value.each do |key, child|
            invalid("string mapping keys") unless key.is_a?(String)
            validate(key, depth + 1)
            validate(child, depth + 1)
          end
        when Array then value.each { |child| validate(child, depth + 1) }
        when String
          invalid("bounded UTF-8 scalar") if value.bytesize > @limits.fetch(:max_string_bytes) || !value.valid_encoding?
        when Integer, Float, true, false, nil then nil
        else invalid("plain data values")
        end
      end

      def invalid(expected)
        raise ConfigError.new("invalid workspace document", path: "$", expected: expected)
      end
    end
    private_constant :Document
  end
end
