# frozen_string_literal: true

require_relative "errors"

module LibTmux
  module Internal
    module Metadata
      module_function

      def format(fields)
        fields.map { |field| "\#{n:#{field}}:\#{q:#{field}}" }.join
      end

      # q doubles literal backslashes before tmux 3.5's VIS_NOSLASH output
      # escaping. Decode that transport layer before using original byte lengths.
      def unquote(value)
        escapes = {"a" => "\a", "b" => "\b", "t" => "\t", "n" => "\n", "v" => "\v",
          "f" => "\f", "r" => "\r", "s" => " ", "E" => "\e"}
        value.b.gsub(/\\([0-7]{3}|.)/n) do
          escaped = Regexp.last_match(1)
          if escaped.match?(/\A[0-7]{3}\z/)
            byte = escaped.to_i(8)
            protocol_error("invalid metadata byte escape") if byte > 255
            byte.chr(Encoding::BINARY)
          else
            escapes.fetch(escaped, escaped)
          end
        end
      end

      def decode(bytes, fields:, max_field_bytes: 1 << 20, max_bytes: 1 << 20, max_rows: 10_000, quoted: false)
        unless bytes.is_a?(String) && fields.is_a?(Integer) && fields.between?(1, 64)
          raise ArgumentError, "metadata requires String bytes and between 1 and 64 fields"
        end
        unless [max_field_bytes, max_bytes, max_rows].all? { |limit| limit.is_a?(Integer) && limit.positive? }
          raise ArgumentError, "metadata limits must be positive integers"
        end
        capacity_error("metadata output exceeds its byte limit") if bytes.bytesize > max_bytes

        bytes = quoted ? unquote(bytes) : bytes.b
        rows = []
        offset = 0
        while offset < bytes.bytesize
          capacity_error("metadata exceeds its row limit") if rows.length >= max_rows
          row = Array.new(fields) do
            length = 0
            digits = 0
            loop do
              byte = bytes.getbyte(offset)
              if byte == 58 && digits.positive?
                offset += 1
                break
              end
              unless byte && byte.between?(48, 57) && digits < 9
                protocol_error("invalid metadata length prefix")
              end
              length = length * 10 + byte - 48
              digits += 1
              offset += 1
            end
            capacity_error("metadata field exceeds its byte limit") if length > max_field_bytes
            protocol_error("truncated metadata field") if offset + length > bytes.bytesize
            value = bytes.byteslice(offset, length).freeze
            offset += length
            value
          end
          protocol_error("missing metadata row terminator") unless bytes.getbyte(offset) == 10
          offset += 1
          rows << row.freeze
        end
        rows.freeze
      end

      def protocol_error(message)
        raise ProtocolError.new(message, delivery: :observed, phase: :decode)
      end
      private_class_method :protocol_error

      def capacity_error(message)
        raise CapacityError.new(message, delivery: :observed, phase: :decode)
      end
      private_class_method :capacity_error
    end
  end
end
