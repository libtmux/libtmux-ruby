# frozen_string_literal: true

require "securerandom"
require_relative "catalog"
require_relative "entity"
require_relative "selection"

module LibTmux
  class CapturedRecord
    attr_reader :capture_id

    def initialize(graph, kind, raw_values, coverage)
      @graph = graph
      @entity_kind = kind
      @capture_id = graph.capture_id
      @raw_values = raw_values
      @coverage = coverage
      @values = raw_values.to_h do |name, raw|
        [name, decode(Internal::Catalog.entity(kind).fields.fetch(name), raw)]
      end.freeze
      @ref = make_ref unless kind == :client
      freeze
    end
    private_class_method :new

    def ref
      if entity_kind == :client
        raise UnsupportedFeatureError, "client observations have no generation-safe command reference"
      end

      @ref
    end

    def raw(name)
      Internal::Catalog.entity(entity_kind).fields.fetch(name)
      ensure_coverage(field_coverage(name)) unless @raw_values.key?(name)
      @raw_values.fetch(name)
    end

    def ==(other)
      other.is_a?(CapturedRecord) && entity_kind == other.__send__(:entity_kind) &&
        capture_id == other.capture_id && identity == other.__send__(:identity)
    end
    alias eql? ==

    def hash
      [capture_id, entity_kind, identity].hash
    end

    def inspect
      "#<#{self.class} captured #{entity_kind}>"
    end

    private

    INVALID_TEXT = Object.new.freeze
    private_constant :INVALID_TEXT
    attr_reader :entity_kind

    def identity
      case entity_kind
      when :window_link then [read_field(:session_id), read_field(:index), read_field(:window_id)]
      when :client then [read_field(:name), read_field(:pid), read_field(:created)]
      else read_field(:id)
      end
    end

    def field_coverage(name)
      Internal::Catalog.entity(entity_kind).fields.fetch(name)
      state = @coverage.fetch(:fields, {}).fetch(name) { @raw_values.key?(name) ? :complete : :unloaded }
      state == :complete && !@raw_values.key?(name) ? :unloaded : state
    end

    def relation_coverage(name)
      relation = Internal::Catalog.entity(entity_kind).relations.fetch(name)
      state = @coverage.fetch(:relations, {}).fetch(name, :complete)
      state == :complete ? @graph.__send__(:relation_coverage, self, relation) : state
    end

    def read_field(name)
      ensure_coverage(field_coverage(name))
      value = @values.fetch(name)
      if value.equal?(INVALID_TEXT)
        raise FieldDecodeError.new("invalid UTF-8 in #{entity_kind}.#{name}", delivery: :observed, phase: :decode)
      end
      value
    end

    def read_relation(name)
      ensure_coverage(relation_coverage(name))
      @graph.__send__(:read_relation, self, name)
    end

    def ensure_coverage(state)
      case state
      when :complete then nil
      when :unsupported then raise UnsupportedFeatureError, "captured value is unsupported"
      else raise IncompleteSnapshotError, "captured value is #{state}"
      end
    end

    def make_ref
      if entity_kind == :window_link
        EntityRef.__send__(:new, binding_key: @graph.binding_key, kind: entity_kind,
          id: read_field(:window_id), session_id: read_field(:session_id), index: read_field(:index))
      else
        EntityRef.__send__(:new, binding_key: @graph.binding_key, kind: entity_kind, id: read_field(:id))
      end
    end

    def decode(field, raw)
      if raw.nil? || (field.empty_is_null && raw.empty?)
        return nil if field.nullable
        decode_error(field)
      end
      case field.type
      when :text
        text = raw.dup.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text.freeze : INVALID_TEXT
      when :integer
        decode_error(field) unless raw.bytesize <= 20 && raw.match?(/\A-?(?:0|[1-9][0-9]*)\z/n)
        value = Integer(raw, 10)
        decode_error(field) unless value.between?(field.min, field.max)
        value
      when :boolean
        return true if raw == "1"
        return false if raw == "0"
        decode_error(field)
      end
    end

    def decode_error(field)
      raise FieldDecodeError.new("invalid #{field.type} in #{field.id}", delivery: :observed, phase: :decode)
    end
  end

  class SessionSnapshot < CapturedRecord; end
  class WindowSnapshot < CapturedRecord; end
  class PaneSnapshot < CapturedRecord; end
  class WindowLinkSnapshot < CapturedRecord; end
  class ClientSnapshot < CapturedRecord; end

  {
    session: SessionSnapshot, window: WindowSnapshot, pane: PaneSnapshot,
    window_link: WindowLinkSnapshot, client: ClientSnapshot
  }.each do |kind, type|
    Internal::Catalog.entity(kind).fields.each_value do |field|
      type.define_method(field.name) { read_field(field.name) }
      type.alias_method(:"#{field.name}?", field.name) if field.type == :boolean
    end
    Internal::Catalog.entity(kind).relations.each_key do |name|
      type.define_method(name) { read_relation(name) }
    end
  end

  # A validated graph observed over an interval, with no transport reference.
  class Snapshot
    attr_reader :capture_id, :binding_key, :started_at, :finished_at, :reads, :server_info, :coverage

    def initialize(rows:, binding_key:, started_at:, finished_at:, reads:, server_info:, coverage: {})
      @capture_id = SecureRandom.hex(16).freeze
      @binding_key = binding_key.dup.freeze
      @started_at = started_at
      @finished_at = finished_at
      unless [started_at, finished_at].all? { |time| time.is_a?(Numeric) && time.finite? } && finished_at >= started_at
        raise ArgumentError, "capture interval must be finite and ordered"
      end
      @reads = own(reads)
      @server_info = own(server_info)
      @coverage = own(coverage)
      validate_coverage
      @source_coverage = Internal::Catalog.kinds.to_h do |kind|
        [kind, @coverage.fetch(kind, {}).fetch(:source) { rows.key?(kind) ? :complete : :unloaded }]
      end.freeze
      @indexes = {}
      @raw_rows = {}
      rows.each do |kind, source|
        schema = Internal::Catalog.entity(kind)
        index = {}
        raw_index = {}
        source.each do |row|
          unknown = row.keys - schema.fields.keys
          raise ArgumentError, "unknown captured field" unless unknown.empty?
          raw = row.to_h do |name, value|
            raise ArgumentError, "captured fields must be byte Strings or nil" unless value.nil? || value.is_a?(String)
            [name, value&.b&.freeze]
          end.freeze
          record = record_type(kind).__send__(:new, self, kind, raw, record_coverage(kind, raw))
          key = own(record.__send__(:identity))
          inconsistent("conflicting repeated #{kind} rows") if raw_index.key?(key) && raw_index.fetch(key) != raw
          raw_index[key] ||= raw
          index[key] ||= record
        end
        @indexes[kind] = index.freeze
        @raw_rows[kind] = raw_index.freeze
      end
      @indexes.freeze
      @raw_rows.freeze
      @panes_by_window = group_records(:pane, :window_id) { |record| record.index }
      @links_by_window = group_records(:window_link, :window_id) { |record| [numeric_id(record.session_id), record.index] }
      @links_by_session = group_records(:window_link, :session_id) { |record| record.index }
      validate_graph
      freeze
    end
    private_class_method :new

    def sessions
      collection(:session)
    end

    def windows
      collection(:window)
    end

    def panes
      collection(:pane)
    end

    def window_links
      collection(:window_link)
    end

    def clients
      collection(:client)
    end

    def resolve(ref)
      unless ref.is_a?(EntityRef) && ref.binding_key == binding_key
        raise TargetNotFoundError, "reference does not belong to this capture binding"
      end
      key = ref.kind == :window_link ? [ref.session_id, ref.index, ref.id] : ref.id
      @indexes.fetch(ref.kind, {}).fetch(key) { raise TargetNotFoundError, "reference is absent from capture" }
    end

    def inspect
      "#<#{self.class} captured graph>"
    end

    private

    EMPTY = [].freeze
    STATES = %i[complete unloaded incomplete unsupported].freeze
    private_constant :EMPTY, :STATES

    def own(value)
      case value
      when String then value.dup.freeze
      when Hash then value.to_h { |key, item| [own(key), own(item)] }.freeze
      when Array then value.map { |item| own(item) }.freeze
      when Symbol, Integer, Float, true, false, nil then value
      else raise ArgumentError, "capture metadata must contain plain immutable values"
      end
    end

    def validate_coverage
      @coverage.each do |kind, spec|
        schema = Internal::Catalog.entity(kind)
        raise ArgumentError, "unknown coverage attribute" unless (spec.keys - %i[source fields relations records]).empty?
        validate_coverage_spec(schema, spec)
        spec.fetch(:records, {}).each_value { |record| validate_coverage_spec(schema, record) }
      end
    end

    def validate_coverage_spec(schema, spec)
      raise ArgumentError, "invalid source coverage" if spec.key?(:source) && !STATES.include?(spec[:source])
      {fields: schema.fields, relations: schema.relations}.each do |name, catalog|
        spec.fetch(name, {}).each do |key, state|
          raise ArgumentError, "invalid captured coverage" unless catalog.key?(key) && STATES.include?(state)
        end
      end
    end

    def record_coverage(kind, raw)
      spec = @coverage.fetch(kind, {})
      key = if kind == :window_link
        [raw[:session_id], raw[:index]&.to_i, raw[:window_id]]
      elsif kind == :client
        [raw[:name], raw[:pid]&.to_i, raw[:created]&.to_i]
      else raw[:id]
      end
      local = spec.fetch(:records, {}).fetch(key, {})
      %i[fields relations].to_h { |name| [name, spec.fetch(name, {}).merge(local.fetch(name, {})).freeze] }.freeze
    end

    def record_type(kind)
      {session: SessionSnapshot, window: WindowSnapshot, pane: PaneSnapshot,
       window_link: WindowLinkSnapshot, client: ClientSnapshot}.fetch(kind)
    end

    def records(kind)
      @indexes.fetch(kind, {}).values
    end

    def source_coverage(kind)
      @source_coverage.fetch(kind)
    end

    def collection(kind)
      ensure_complete(source_coverage(kind))
      ordered = records(kind).sort_by do |record|
        case kind
        when :window_link then [numeric_id(record.session_id), record.index]
        when :client then [record.pid, record.created, record.raw(:name)]
        else numeric_id(record.id)
        end
      end
      selection(ordered, kind)
    end

    def selection(values, kind)
      Selection.new(values, entity: kind, graph: self)
    end

    def numeric_id(id)
      Integer(id.byteslice(1..), 10)
    end

    def group_records(kind, field)
      records(kind).group_by { |record| record.__send__(:read_field, field) }
        .transform_values { |group| group.sort_by { |record| yield record }.freeze }.freeze
    end

    def relation_coverage(record, relation)
      if record.__send__(:entity_kind) == :client && relation.name == :session
        state = record.__send__(:field_coverage, :session_id)
        return state unless state == :complete
        return :complete if record.session_id.nil?
      end
      states = relation.capture_requirements.map { |kind| source_coverage(kind) }
      return :unsupported if states.include?(:unsupported)
      return :unloaded if states.include?(:unloaded)
      return :incomplete if states.include?(:incomplete)

      children = case [record.__send__(:entity_kind), relation.name]
      when [:window, :active_pane] then @panes_by_window.fetch(record.id, EMPTY)
      when [:session, :current_window] then @links_by_session.fetch(record.id, EMPTY)
      end
      if children
        states = children.map { |child| child.__send__(:field_coverage, :active) }
        return :unsupported if states.include?(:unsupported)
        return :unloaded if states.include?(:unloaded)
        return :incomplete if states.include?(:incomplete)
      end
      :complete
    end

    def read_relation(record, name)
      kind = record.__send__(:entity_kind)
      case [kind, name]
      when [:pane, :window], [:window_link, :window]
        @indexes.fetch(:window).fetch(record.window_id)
      when [:window_link, :session]
        @indexes.fetch(:session).fetch(record.session_id)
      when [:client, :session]
        record.session_id && @indexes.fetch(:session).fetch(record.session_id)
      when [:window, :panes]
        selection(@panes_by_window.fetch(record.id, EMPTY), :pane)
      when [:window, :window_links]
        selection(@links_by_window.fetch(record.id, EMPTY), :window_link)
      when [:window, :active_pane]
        @panes_by_window.fetch(record.id, EMPTY).find(&:active?)
      when [:session, :window_links]
        selection(@links_by_session.fetch(record.id, EMPTY), :window_link)
      when [:session, :windows]
        selection(@links_by_session.fetch(record.id, EMPTY).map { |link| @indexes.fetch(:window).fetch(link.window_id) }, :window)
      when [:session, :panes]
        selection(@links_by_session.fetch(record.id, EMPTY).flat_map { |link| @panes_by_window.fetch(link.window_id, EMPTY) }, :pane)
      when [:session, :current_window]
        link = @links_by_session.fetch(record.id, EMPTY).find(&:active?)
        link && @indexes.fetch(:window).fetch(link.window_id)
      end
    end

    def validate_graph
      records(:pane).each { |pane| validate_edge(:window, pane.window_id) }
      placements = {}
      records(:window_link).each do |link|
        validate_edge(:session, link.session_id)
        validate_edge(:window, link.window_id)
        key = [link.session_id, link.index]
        inconsistent("conflicting window placement") if placements.key?(key)
        placements[key] = true
      end
      records(:client).each do |client|
        next unless client.__send__(:field_coverage, :session_id) == :complete
        validate_edge(:session, client.session_id) if client.session_id
      end
      records(:window).each do |window|
        next unless source_coverage(:pane) == :complete
        panes = @panes_by_window.fetch(window.id, EMPTY)
        inconsistent("duplicate pane index") unless panes.map(&:index).uniq.size == panes.size
        validate_count(window, :pane_count, panes)
        validate_active(panes)
      end
      records(:session).each do |session|
        next unless source_coverage(:window_link) == :complete
        links = @links_by_session.fetch(session.id, EMPTY)
        validate_count(session, :window_count, links)
        validate_active(links)
      end
    end

    def validate_edge(kind, id)
      return unless source_coverage(kind) == :complete
      inconsistent("broken #{kind} reference") unless @indexes.fetch(kind, {}).key?(id)
    end

    def validate_count(record, field, children)
      return unless record.__send__(:field_coverage, field) == :complete
      inconsistent("captured child count changed") unless record.__send__(:read_field, field) == children.size
    end

    def validate_active(children)
      return if children.empty? || children.any? { |child| child.__send__(:field_coverage, :active) != :complete }
      inconsistent("captured active child changed") unless children.count(&:active?) == 1
    end

    def ensure_complete(state)
      return if state == :complete
      raise UnsupportedFeatureError, "capture source is unsupported" if state == :unsupported
      raise IncompleteSnapshotError, "capture source is #{state}"
    end

    def inconsistent(message)
      raise InconsistentSnapshotError.new(message, delivery: :observed, phase: :capture)
    end
  end
end
