# frozen_string_literal: true

require_relative "criteria"

module LibTmux
  module Internal
    # Capturing all relation evidence is the conservative source plan.
    class SourceQuery
      COLLECTIONS = {session: :sessions, window: :windows, pane: :panes,
                     window_link: :window_links, client: :clients}.freeze
      private_constant :COLLECTIONS

      def initialize(entity, where:, pushdown: :auto)
        unless %i[auto never required].include?(pushdown)
          raise ArgumentError, "pushdown must be :auto, :never or :required"
        end
        @expression = FilterExpr.build(entity, where)
        @entity = entity
        @collection = COLLECTIONS.fetch(entity)
        @pushdown = pushdown
        reasons = pushdown == :never ? [] : ["no tmux predicate compiler has passed differential verification"]
        @explanation = freeze_tree({entity: entity, requested_pushdown: pushdown,
          capture: :full_graph, capture_requirements: %i[session window window_link pane] + (entity == :client ? [:client] : []),
          pushed: nil, residual: @expression.to_h, executable: pushdown != :required,
          rejected_optimization_reasons: reasons})
        freeze
      end

      def explain
        @explanation
      end

      def inspect
        "#<#{self.class} entity=#{@entity} capture=full_graph pushdown=#{@pushdown}>"
      end

      def execute(server, **options)
        if @pushdown == :required
          raise UnsupportedFeatureError.new("required pushdown has no verified exact compiler; use :auto or :never", phase: :plan)
        end
        options = options.merge(clients: true) if @entity == :client
        server.snapshot(**options).public_send(@collection).where(@expression)
      end

      private

      def freeze_tree(value)
        case value
        when Hash then value.to_h { |key, child| [key, freeze_tree(child)] }.freeze
        when Array then value.map { |child| freeze_tree(child) }.freeze
        when String then value.dup.freeze
        else value
        end
      end
    end
  end
end
