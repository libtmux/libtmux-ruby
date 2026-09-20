# frozen_string_literal: true

module LibTmux
  module MCP
    # Handshake metadata does not need schemas. Validate each through the SDK
    # before exposing it; Application validates both before dispatching effects.
    class CatalogTool < ::MCP::Tool
      class << self
        def define(input_schema:, output_schema:, **metadata, &block)
          super(**metadata, &block).tap do |tool|
            tool.instance_variable_set(:@input_definition, input_schema)
            tool.instance_variable_set(:@output_definition, output_schema)
          end
        end

        def input_schema_value
          @input_schema_value ||= ::MCP::Tool::InputSchema.new(@input_definition)
        end

        def output_schema_value
          @output_schema_value ||= ::MCP::Tool::OutputSchema.new(@output_definition)
        end

        def to_h
          input_schema_value
          output_schema_value
          super
        end
      end
    end
    private_constant :CatalogTool
  end
end
