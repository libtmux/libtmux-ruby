# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "catalog"

module LibTmux
  # A schema-validated predicate over captured records; evaluation performs no I/O.
  class FilterExpr
    # Runtime validation also enforces byte, node, depth and duplicate-key limits.
    def self.json_schema
      JSON.parse(File.binread(File.expand_path("../../schema/where-v1.json", __dir__)), freeze: true)
    end

    PROFILE = "libtmux-ruby.where"
    VERSION = 1
    OMITTED = Object.new.freeze
    OPERATORS = {
      equals: "equals", not: "not", in: "in", lt: "lt", lte: "lte",
      gt: "gt", gte: "gte", contains: "contains", starts_with: "startsWith",
      ends_with: "endsWith", some: "some", every: "every", none: "none",
      is: "is", is_not: "isNot"
    }.freeze
    MAX_DEPTH = 32
    MAX_NODES = 2048
    MAX_MEMBERS = 1024
    MAX_STRING_BYTES = 65_536
    MAX_BYTES = 262_144
    private_constant :OMITTED, :OPERATORS, :MAX_DEPTH, :MAX_NODES, :MAX_MEMBERS,
      :MAX_STRING_BYTES, :MAX_BYTES

    attr_reader :entity

    def self.build(entity, criteria = OMITTED, **keywords, &block)
      raise ArgumentError, "criteria do not accept a block" if block
      unless Internal::Catalog.kinds.include?(entity)
        raise InvalidFilterError.new(path: "$.entity", expected: "declared entity schema")
      end
      unless criteria.equal?(OMITTED) || keywords.empty?
        raise ArgumentError, "use positional or keyword criteria, not both"
      end
      criteria = keywords if criteria.equal?(OMITTED)
      if criteria.is_a?(self)
        unless criteria.entity == entity
          raise InvalidFilterError.new(entity: entity, expected: "matching entity schema")
        end
        return criteria
      end
      schema = Internal::Catalog.entity(entity)
      tree = Normalizer.new(schema.kind).normalize(schema, criteria)
      new(schema.kind, tree)
    end

    def self.from_json(input)
      unless input.is_a?(String) && input.bytesize <= MAX_BYTES
        raise InvalidFilterError.new(expected: "JSON string of at most #{MAX_BYTES} bytes")
      end
      data = JSON.parse(input, max_nesting: MAX_DEPTH * 2 + 4,
        allow_nan: false, allow_duplicate_key: false)
      required = %w[profile version entity where]
      unless data.is_a?(Hash) && data.keys.sort == required.sort &&
          data["profile"] == PROFILE && data["version"].is_a?(Integer) && data["version"] == VERSION
        raise InvalidFilterError.new(expected: "#{PROFILE} version #{VERSION} envelope")
      end
      entity = %i[session window pane window_link client].find do |kind|
        Internal::Catalog.entity(kind).wire_entity == data["entity"]
      end
      raise InvalidFilterError.new(path: "$.entity", expected: "declared entity") unless entity

      schema = Internal::Catalog.entity(entity)
      new(entity, Normalizer.new(entity, wire: true).normalize(schema, data["where"]))
    rescue JSON::ParserError, JSON::NestingError, EncodingError
      raise InvalidFilterError.new(expected: "bounded UTF-8 JSON object"), cause: nil
    end

    def initialize(entity, tree)
      @entity = entity
      @tree = tree
      freeze
    end
    private_class_method :new

    def and(other)
      compose(:and, other)
    end

    def or(other)
      compose(:or, other)
    end

    def not
      self.class.build(entity, not: @tree)
    end

    def call(record)
      preflight([record])
      matches(record, @tree)
    end
    alias === call

    def to_proc
      method(:call).to_proc
    end

    def to_h
      {"profile" => PROFILE, "version" => VERSION,
       "entity" => Internal::Catalog.entity(entity).wire_entity,
       "where" => wire_tree(Internal::Catalog.entity(entity), @tree)}
    end

    def to_json(*arguments)
      output = JSON.generate(to_h, *arguments)
      if output.bytesize > MAX_BYTES
        raise InvalidFilterError.new(entity: entity, expected: "wire envelope of at most #{MAX_BYTES} bytes", phase: :serialize)
      end
      output
    end

    def inspect
      "#<#{self.class} entity=#{entity} profile=#{PROFILE} version=#{VERSION}>"
    end

    private

    def compose(operator, other)
      unless other.is_a?(FilterExpr) && other.entity == entity
        raise InvalidFilterError.new(entity: entity, expected: "matching FilterExpr")
      end
      self.class.build(entity, operator => [@tree, other.instance_variable_get(:@tree)])
    end

    def preflight(records)
      records.each do |record|
        unless record.respond_to?(:entity_kind, true) && record.__send__(:entity_kind) == entity
          raise InvalidFilterError.new(entity: entity, expected: "captured #{entity} record")
        end
        preflight_tree(record, Internal::Catalog.entity(entity), @tree)
      end
    end

    def select_records(records)
      preflight(records)
      records.select { |record| matches(record, @tree) }
    end

    def preflight_tree(record, schema, tree, path = "$")
      tree.each do |name, condition|
        child_path = "#{path}.#{name}"
        case name
        when :and, :or
          condition.each_with_index { |child, index| preflight_tree(record, schema, child, "#{child_path}[#{index}]") }
        when :not
          preflight_tree(record, schema, condition, child_path)
        else
          if schema.fields.key?(name)
            require_complete(record, :field, name, child_path)
            begin
              record.__send__(:read_field, name)
            rescue FieldDecodeError
              raise FieldDecodeError.new("captured field cannot be decoded at #{child_path}",
                entity: entity, path: child_path, expected: "valid captured #{schema.fields.fetch(name).type}", phase: :evaluate)
            end
          else
            relation = schema.relations.fetch(name)
            require_complete(record, :relation, name, child_path)
            value = record.__send__(:read_relation, name)
            children = relation.cardinality == :many ? value : [value].compact
            condition.each_pair do |operator, child_tree|
              next if child_tree.nil?

              children.each do |child|
                preflight_tree(child, Internal::Catalog.entity(relation.target), child_tree, "#{child_path}.#{operator}")
              end
            end
          end
        end
      end
    end

    def require_complete(record, category, name, path)
      return if record.__send__(:"#{category}_coverage", name) == :complete

      raise IncompleteSnapshotError.new("required #{category} was not completely captured at #{path}",
        entity: entity, path: path, expected: "complete captured #{category}", phase: :evaluate)
    end

    def matches(record, tree)
      schema = Internal::Catalog.entity(record.__send__(:entity_kind))
      tree.all? do |name, condition|
        case name
        when :and then condition.all? { |child| matches(record, child) }
        when :or then condition.any? { |child| matches(record, child) }
        when :not then !matches(record, condition)
        else
          if schema.fields.key?(name)
            scalar_matches(record.__send__(:read_field, name), condition)
          else
            value = record.__send__(:read_relation, name)
            condition.all? do |operator, child|
              case operator
              when :some then value.any? { |item| matches(item, child) }
              when :every then value.all? { |item| matches(item, child) }
              when :none then value.none? { |item| matches(item, child) }
              when :is then child.nil? ? value.nil? : !value.nil? && matches(value, child)
              when :is_not then child.nil? ? !value.nil? : value.nil? || !matches(value, child)
              end
            end
          end
        end
      end
    end

    def scalar_matches(value, condition)
      condition.all? do |operator, expected|
        case operator
        when :equals then value == expected
        when :not then !scalar_matches(value, expected)
        when :in then expected.include?(value)
        when :lt then !value.nil? && value < expected
        when :lte then !value.nil? && value <= expected
        when :gt then !value.nil? && value > expected
        when :gte then !value.nil? && value >= expected
        when :contains then !value.nil? && value.include?(expected)
        when :starts_with then !value.nil? && value.start_with?(expected)
        when :ends_with then !value.nil? && value.end_with?(expected)
        end
      end
    end

    def wire_tree(schema, tree)
      tree.to_h do |name, condition|
        case name
        when :and, :or then [name.to_s, condition.map { |child| wire_tree(schema, child) }]
        when :not then ["not", wire_tree(schema, condition)]
        else
          if (field = schema.fields[name])
            [field.wire_name, wire_scalar(condition)]
          else
            relation = schema.relations.fetch(name)
            child_schema = Internal::Catalog.entity(relation.target)
            [relation.wire_name, condition.to_h { |op, child| [OPERATORS.fetch(op), child.nil? ? nil : wire_tree(child_schema, child)] }]
          end
        end
      end
    end

    def wire_scalar(condition)
      condition.to_h { |op, value| [OPERATORS.fetch(op), op == :not ? wire_scalar(value) : duplicate_value(value)] }
    end

    def duplicate_value(value)
      case value
      when Array then value.map { |item| duplicate_value(item) }
      when String then value.dup
      else value
      end
    end

    class Normalizer
      def initialize(entity, wire: false)
        @entity = entity
        @wire = wire
        @nodes = 0
        @bytes = 0
      end

      def normalize(schema, input, path = "$", depth = 0)
        visit(path, depth)
        fail_at(path, "criteria object") unless input.is_a?(Hash)
        output = {}
        input.each do |key, value|
          name = lookup(key, schema)
          fail_at(path, "declared field, relation or Boolean operator") unless name
          child_path = "#{path}.#{name}"
          fail_at(child_path, "one spelling of each key") if output.key?(name)
          output[name] = case name
          when :and, :or
            fail_at(child_path, "array of criteria") unless value.is_a?(Array)
            fail_at(child_path, "bounded criteria array") if value.length > MAX_NODES
            value.each_with_index.map { |child, index| normalize(schema, child, "#{child_path}[#{index}]", depth + 1) }.freeze
          when :not then normalize(schema, value, child_path, depth + 1)
          else
            if (field = schema.fields[name])
              scalar(field, value, child_path, depth + 1)
            else
              relation(schema.relations.fetch(name), value, child_path, depth + 1)
            end
          end
        end
        output.freeze
      end

      private

      def visit(path, depth)
        @nodes += 1
        fail_at(path, "depth <= #{MAX_DEPTH} and nodes <= #{MAX_NODES}") if depth > MAX_DEPTH || @nodes > MAX_NODES
      end

      def lookup(key, schema)
        return unless key.is_a?(String) || key.is_a?(Symbol)

        text = key.to_s
        return text.to_sym if %w[and or not].include?(text)

        schema.fields.each_value do |field|
          return field.name if (!@wire && text == field.name.to_s) || text == field.wire_name
        end
        schema.relations.each_value do |relation|
          return relation.name if (!@wire && text == relation.name.to_s) || text == relation.wire_name
        end
        nil
      end

      def scalar(field, input, path, depth)
        visit(path, depth)
        input = {equals: input} unless input.is_a?(Hash)
        fail_at(path, "nonempty scalar operator object") if input.empty?
        output = {}
        input.each do |key, value|
          op = operator(key)
          fail_at(path, "declared #{field.type} operator") unless op && field.operators.include?(op)
          current_path = "#{path}.#{op}"
          fail_at(current_path, "one spelling of each operator") if output.key?(op)
          output[op] = case op
          when :not then scalar(field, value, current_path, depth + 1)
          when :in
            unless value.is_a?(Array) && value.length <= MAX_MEMBERS
              fail_at(current_path, "array of at most #{MAX_MEMBERS} members")
            end
            value.each_with_index.map { |item, index| literal(field, item, "#{current_path}[#{index}]", nullable: true) }.freeze
          else literal(field, value, current_path, nullable: op == :equals)
          end
        end
        output.freeze
      end

      def relation(relation, input, path, depth)
        visit(path, depth)
        fail_at(path, "nonempty relation operator object") unless input.is_a?(Hash) && !input.empty?
        allowed = relation.cardinality == :many ? %i[some every none] : %i[is is_not]
        output = {}
        input.each do |key, value|
          op = operator(key)
          fail_at(path, allowed.join(" or ")) unless allowed.include?(op)
          child_path = "#{path}.#{op}"
          fail_at(child_path, "one spelling of each operator") if output.key?(op)
          if value.nil?
            fail_at(child_path, "criteria object for nonnullable relation") unless relation.nullable && relation.cardinality == :one
            output[op] = nil
          else
            output[op] = normalize(Internal::Catalog.entity(relation.target), value, child_path, depth + 1)
          end
        end
        output.freeze
      end

      def operator(key)
        return unless key.is_a?(String) || key.is_a?(Symbol)

        OPERATORS.each_pair do |name, wire|
          return name if (!@wire && key.to_s == name.to_s) || key.to_s == wire
        end
        nil
      end

      def literal(field, value, path, nullable:)
        @nodes += 1
        fail_at(path, "bounded node count") if @nodes > MAX_NODES
        return nil if value.nil? && nullable && field.nullable

        case field.type
        when :integer
          unless value.is_a?(Integer) && (!field.min || value >= field.min) && (!field.max || value <= field.max)
            fail_at(path, "integer within catalog bounds")
          end
          value
        when :boolean
          fail_at(path, "Boolean") unless value.equal?(true) || value.equal?(false)
          value
        when :string, :text, :id
          fail_at(path, "UTF-8 string") unless value.is_a?(String)
          text = value.dup.force_encoding(Encoding::UTF_8)
          fail_at(path, "UTF-8 string") unless text.valid_encoding?
          @bytes += text.bytesize
          if text.bytesize > MAX_STRING_BYTES || @bytes > MAX_BYTES
            fail_at(path, "bounded UTF-8 string")
          end
          text.freeze
        else
          fail_at(path, "queryable catalog field")
        end
      end

      def fail_at(path, expected)
        raise InvalidFilterError.new(entity: @entity, path: path, expected: expected)
      end
    end
    private_constant :Normalizer
  end

  {SessionWhere: :session, WindowWhere: :window, PaneWhere: :pane,
   WindowLinkWhere: :window_link, ClientWhere: :client}.each do |name, entity|
    builder = Module.new
    builder.define_singleton_method(:build) do |*arguments, **keywords, &block|
      FilterExpr.build(entity, *arguments, **keywords, &block)
    end
    const_set(name, builder.freeze)
  end
end
