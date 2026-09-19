# frozen_string_literal: true

module LibTmux
  module MCP
    module Catalog
      READ_ONLY = %w[tmux_capabilities tmux_snapshot].freeze
      MUTATIONS = %w[tmux_send tmux_create tmux_close].freeze
      NAMES = (READ_ONLY + MUTATIONS).freeze
      MUTATION_BYTES = 1 << 16
      MIN_MUTATION_RESPONSE_BYTES = 4096

      def self.object(properties, required = properties.keys)
        {"type" => "object", "properties" => properties, "required" => required, "additionalProperties" => false}
      end

      def self.text
        {"type" => "string"}
      end

      def self.input(name)
        return object({}) if name == "tmux_capabilities"
        return mutation_input(name) if MUTATIONS.include?(name)

        criteria = FilterExpr.json_schema
        object({"entity" => {"enum" => Internal::Catalog.kinds.map(&:to_s)},
          "criteria" => {"oneOf" => criteria.fetch("oneOf")},
          "limit" => {"type" => "integer", "minimum" => 1, "maximum" => 200},
          "cursor" => {"type" => "string", "pattern" => "^[a-f0-9]{32}:[0-9]{1,10}$", "maxLength" => 43}}, []).merge(
          "$defs" => criteria.fetch("$defs"), "oneOf" => [
            {"required" => ["entity"], "not" => {"required" => ["cursor"]}},
            {"required" => ["cursor"], "not" => {"anyOf" => %w[entity criteria limit].map { |key| {"required" => [key]} }}}
          ])
      end

      def self.identity
        object({"generation" => text, "pid" => {"type" => "integer"},
          "start_time" => {"type" => "integer"}, "tmux_version" => text})
      end

      def self.reference(kind = nil)
        kinds = kind ? [kind] : %w[session window pane window_link]
        {"oneOf" => kinds.map do |entity|
          prefix = {"session" => "\\$", "window" => "@", "pane" => "%", "window_link" => "@"}.fetch(entity)
          properties = {"generation" => text.merge("minLength" => 1, "maxLength" => 128), "kind" => {"const" => entity},
            "id" => text.merge("pattern" => "^#{prefix}[0-9]+$", "maxLength" => 32)}
          if entity == "window_link"
            properties.merge!("session_id" => text.merge("pattern" => "^\\$[0-9]+$", "maxLength" => 32),
              "index" => {"type" => "integer", "minimum" => 0})
          end
          object(properties)
        end}
      end

      def self.mutation_text
        text.merge("maxLength" => MUTATION_BYTES, "pattern" => "^[^\\u0000]*$")
      end

      def self.mutation_input(name)
        case name
        when "tmux_send"
          {"oneOf" => [object({"target" => reference("pane"), "input" => {"oneOf" => [
            object({"type" => {"const" => "text"}, "text" => mutation_text}),
            object({"type" => {"const" => "keys"}, "keys" => {"type" => "array", "minItems" => 1, "maxItems" => 256,
              "items" => mutation_text.merge("minLength" => 1)}})
          ]}})]}
        when "tmux_close"
          {"oneOf" => [object({"target" => {"oneOf" => %w[session window pane].flat_map { |kind| reference(kind).fetch("oneOf") }}})]}
        when "tmux_create"
          common = {"argv" => {"type" => "array", "minItems" => 1, "maxItems" => 256,
            "prefixItems" => [mutation_text.merge("minLength" => 1)], "items" => mutation_text},
            "cwd" => mutation_text.merge("minLength" => 1),
            "environment" => {"type" => "object", "maxProperties" => 128,
              "propertyNames" => {"pattern" => "^[A-Za-z_][A-Za-z0-9_]*$"}, "additionalProperties" => mutation_text}}
          positive = {"type" => "integer", "minimum" => 1, "maximum" => (1 << 31) - 1}
          {"oneOf" => [
            object(common.merge("kind" => {"const" => "session"}, "name" => mutation_text.merge("minLength" => 1),
              "window_name" => mutation_text.merge("minLength" => 1), "width" => positive, "height" => positive), %w[kind name argv]),
            object(common.merge("kind" => {"const" => "window"}, "parent" => reference("session"),
              "name" => mutation_text.merge("minLength" => 1), "index" => {"type" => "integer", "minimum" => 0, "maximum" => (1 << 31) - 1},
              "focus" => {"type" => "boolean"}), %w[kind parent name argv]),
            object(common.merge("kind" => {"const" => "pane"}, "parent" => reference("pane"),
              "direction" => {"enum" => %w[horizontal vertical]}, "size" => {"oneOf" => [positive,
                {"type" => "string", "pattern" => "^(?:[1-9][0-9]?|100)%$"}]},
              "focus" => {"type" => "boolean"}), %w[kind parent direction argv])
          ]}
        end
      end

      def self.record
        {"oneOf" => Internal::Catalog.kinds.map do |kind|
          fields = Internal::Catalog.entity(kind).fields.values.to_h do |field|
            type = {text: "string", integer: "integer", boolean: "boolean"}.fetch(field.type)
            schema = {"type" => field.nullable ? [type, "null"] : type}
            schema["minimum"] = field.min if field.min
            schema["maximum"] = field.max if field.max
            [field.wire_name, schema]
          end
          object({"kind" => {"const" => kind.to_s}, "fields" => object(fields),
            "ref" => kind == :client ? {"type" => "null"} : reference(kind.to_s)})
        end}
      end

      def self.output(name)
        payload = if MUTATIONS.include?(name)
          mutation_output(name)
        elsif name == "tmux_capabilities"
          object({"endpoint" => text, "server_identity" => identity,
            "enabled_tools" => {"type" => "array", "items" => text},
            "criteria_schema" => {"type" => "object"},
            "limits" => {"type" => "object", "additionalProperties" => {"type" => "number"}},
            "owns_daemon" => {"const" => false}, "resource_subscriptions" => {"const" => false}})
        else
          object({"capture_id" => text, "server_identity" => identity,
            "entity" => {"enum" => Internal::Catalog.kinds.map(&:to_s)},
            "items" => {"type" => "array", "items" => record, "maxItems" => 200},
            "coverage" => {"type" => "object", "additionalProperties" => {"enum" => %w[complete unloaded]}},
            "interval" => object({"clock" => {"const" => "monotonic_seconds"},
              "started" => {"type" => "number"}, "finished" => {"type" => "number"},
              "reads" => {"type" => "integer", "minimum" => 0}}),
            "truncated" => {"type" => "boolean"}, "next_cursor" => text},
            %w[capture_id server_identity entity items coverage interval truncated])
        end
        {"oneOf" => [object({"ok" => {"const" => true}, "data" => payload}),
          object({"ok" => {"const" => false}, "error" => object({"code" => text,
            "message" => text, "delivery" => {"enum" => %w[not_sent possibly_sent observed]},
            "effects" => effects}, %w[code message delivery])})]}
      end

      def self.effects
        object({"state" => {"enum" => %w[none known unknown]},
          "created" => {"type" => "array", "maxItems" => 3, "items" => reference}})
      end

      def self.mutation_output(name)
        if name == "tmux_create"
          object({"entity" => reference, "created" => {"type" => "array", "minItems" => 1, "maxItems" => 3, "items" => reference},
            "delivery" => {"const" => "observed"}, "program_completion" => {"const" => "unobserved"}})
        else
          properties = {"target" => reference, "delivery" => {"const" => "observed"},
            "client_exit_status" => {"const" => 0}}
          properties["completion"] = {"const" => "dispatch_only"} if name == "tmux_send"
          object(properties)
        end
      end

      def self.description(name)
        if name == "tmux_send"
          "Send literal UTF-8 text or named keys to one exact pane. Opt-in mutation; 64 KiB total text bytes, at most 256 keys. Reports tmux client completion and input dispatch only; never shell completion."
        elsif name == "tmux_create"
          "Create a session, window in an exact session, or split an exact pane using argv. Opt-in mutation; 64 KiB total string bytes and at most 256 argv entries. Window/pane focus defaults false. Cwd/environment are optional; size is cells or percent. Assigned refs prove creation, not program readiness or completion."
        elsif name == "tmux_close"
          "Destroy one exact session, window or pane. Opt-in destructive operation; closing a session or window also removes its contained topology. Never selects by name or closes the daemon directly. Returns the final tmux client outcome."
        elsif name == "tmux_capabilities"
          "Discover the fixed endpoint, server binding, enabled tools, criteria schema and limits. Acquires metadata; starts no daemon."
        else
          "Capture ordered metadata and evaluate Ruby criteria locally. Pages retain one immutable capture; expired cursors require a new query. Limit defaults to 50 records, maximum 200."
        end
      end
    end
    private_constant :Catalog
  end
end
