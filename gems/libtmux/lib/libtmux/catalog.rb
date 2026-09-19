# frozen_string_literal: true

module LibTmux
  module Internal
    # Names and bounds are explicit: wire spelling is not Ruby case conversion.
    module Catalog
      Field = Data.define(:id, :name, :wire_name, :type, :nullable, :empty_is_null, :min, :max,
        :operators, :format, :min_version, :scope, :capture_requirements)
      Relation = Data.define(:name, :wire_name, :target, :cardinality, :nullable,
        :capture_requirements)
      Schema = Data.define(:kind, :wire_entity, :fields, :relations)

      EQUALITY = %i[equals not in].freeze
      INTEGER = (EQUALITY + %i[lt lte gt gte]).freeze
      TEXT = (EQUALITY + %i[contains starts_with ends_with]).freeze
      UINT_MAX = (1 << 32) - 1
      INT_MAX = (1 << 31) - 1
      TIME_MIN = -(1 << 63)
      TIME_MAX = (1 << 63) - 1
      private_constant :EQUALITY, :INTEGER, :TEXT, :UINT_MAX, :INT_MAX, :TIME_MIN, :TIME_MAX

      def self.field(scope, id, name, wire_name, format, type, nullable: false, empty_is_null: false, min: nil, max: nil, operators: nil)
        Field.new(id: id, name: name, wire_name: wire_name, format: format, type: type,
          nullable: nullable, empty_is_null: empty_is_null, min: min, max: max,
          operators: operators || {text: TEXT, integer: INTEGER, boolean: EQUALITY}.fetch(type),
          min_version: "3.2a", scope: scope, capture_requirements: [scope].freeze)
      end
      private_class_method :field

      def self.relation(name, wire_name, target, cardinality, *requirements, nullable: false)
        Relation.new(name: name, wire_name: wire_name, target: target, cardinality: cardinality,
          nullable: nullable, capture_requirements: requirements.freeze)
      end
      private_class_method :relation

      def self.schema(kind, wire_entity, fields, relations)
        Schema.new(kind: kind, wire_entity: wire_entity,
          fields: fields.to_h { |field| [field.name, field] }.freeze,
          relations: relations.to_h { |relation| [relation.name, relation] }.freeze)
      end
      private_class_method :schema

      # 3.2a is the supported capture baseline, not a claim about first introduction.
      SCHEMAS = {
        session: schema(:session, "session", [
          field(:session, "session.id", :id, "id", "session_id", :text, operators: EQUALITY),
          field(:session, "session.name", :name, "name", "session_name", :text),
          field(:session, "session.created", :created, "created", "session_created", :integer, min: TIME_MIN, max: TIME_MAX),
          field(:session, "session.attached", :attached, "attached", "session_attached", :integer, min: 0, max: UINT_MAX),
          field(:session, "session.window_count", :window_count, "windowCount", "session_windows", :integer, min: 0, max: UINT_MAX)
        ], [
          relation(:windows, "windows", :window, :many, :window_link, :window),
          relation(:window_links, "windowLinks", :window_link, :many, :window_link),
          relation(:panes, "panes", :pane, :many, :window_link, :window, :pane),
          relation(:current_window, "currentWindow", :window, :one, :window_link, :window, nullable: true)
        ]),
        window: schema(:window, "window", [
          field(:window, "window.id", :id, "id", "window_id", :text, operators: EQUALITY),
          field(:window, "window.name", :name, "name", "window_name", :text),
          field(:window, "window.width", :width, "width", "window_width", :integer, min: 0, max: UINT_MAX),
          field(:window, "window.height", :height, "height", "window_height", :integer, min: 0, max: UINT_MAX),
          field(:window, "window.pane_count", :pane_count, "paneCount", "window_panes", :integer, min: 0, max: UINT_MAX),
          field(:window, "window.layout", :layout, "layout", "window_layout", :text)
        ], [
          relation(:panes, "panes", :pane, :many, :pane),
          relation(:window_links, "windowLinks", :window_link, :many, :window_link),
          relation(:active_pane, "activePane", :pane, :one, :pane, nullable: true)
        ]),
        pane: schema(:pane, "pane", [
          field(:pane, "pane.id", :id, "id", "pane_id", :text, operators: EQUALITY),
          field(:pane, "pane.window_id", :window_id, "windowId", "window_id", :text, operators: EQUALITY),
          field(:pane, "pane.index", :index, "index", "pane_index", :integer, min: 0, max: UINT_MAX),
          field(:pane, "pane.pid", :pid, "pid", "pane_pid", :integer, min: 0, max: INT_MAX),
          field(:pane, "pane.current_command", :current_command, "currentCommand", "pane_current_command", :text),
          field(:pane, "pane.current_path", :current_path, "currentPath", "pane_current_path", :text, nullable: true, empty_is_null: true),
          field(:pane, "pane.title", :title, "title", "pane_title", :text),
          field(:pane, "pane.active", :active, "active", "pane_active", :boolean),
          field(:pane, "pane.dead", :dead, "dead", "pane_dead", :boolean),
          field(:pane, "pane.dead_status", :dead_status, "deadStatus", "pane_dead_status", :integer, nullable: true, empty_is_null: true, min: 0, max: 255),
          field(:pane, "pane.width", :width, "width", "pane_width", :integer, min: 0, max: UINT_MAX),
          field(:pane, "pane.height", :height, "height", "pane_height", :integer, min: 0, max: UINT_MAX)
        ], [relation(:window, "window", :window, :one, :window)]),
        window_link: schema(:window_link, "window_link", [
          field(:window_link, "window_link.session_id", :session_id, "sessionId", "session_id", :text, operators: EQUALITY),
          field(:window_link, "window_link.window_id", :window_id, "windowId", "window_id", :text, operators: EQUALITY),
          field(:window_link, "window_link.index", :index, "index", "window_index", :integer, min: 0, max: INT_MAX),
          field(:window_link, "window_link.active", :active, "active", "window_active", :boolean)
        ], [
          relation(:session, "session", :session, :one, :session),
          relation(:window, "window", :window, :one, :window)
        ]),
        client: schema(:client, "client", [
          field(:client, "client.name", :name, "name", "client_name", :text),
          field(:client, "client.pid", :pid, "pid", "client_pid", :integer, min: 0, max: INT_MAX),
          field(:client, "client.created", :created, "created", "client_created", :integer, min: TIME_MIN, max: TIME_MAX),
          field(:client, "client.tty", :tty, "tty", "client_tty", :text, nullable: true, empty_is_null: true),
          field(:client, "client.session_id", :session_id, "sessionId", "session_id", :text, nullable: true, empty_is_null: true, operators: EQUALITY),
          field(:client, "client.width", :width, "width", "client_width", :integer, min: 0, max: UINT_MAX),
          field(:client, "client.height", :height, "height", "client_height", :integer, nullable: true, empty_is_null: true, min: 0, max: UINT_MAX),
          field(:client, "client.read_only", :read_only, "readOnly", "client_readonly", :boolean),
          field(:client, "client.utf8", :utf8, "utf8", "client_utf8", :boolean),
          field(:client, "client.control_mode", :control_mode, "controlMode", "client_control_mode", :boolean)
        ], [relation(:session, "session", :session, :one, :session, nullable: true)])
      }.freeze
      private_constant :SCHEMAS

      def self.entity(kind)
        SCHEMAS.fetch(kind)
      end

      def self.kinds
        SCHEMAS.keys.freeze
      end
    end
  end
end
