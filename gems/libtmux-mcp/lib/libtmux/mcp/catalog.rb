# frozen_string_literal: true

module LibTmux
  module MCP
    module Catalog
      READ_ONLY = %w[tmux_capabilities tmux_snapshot].freeze
      MUTATIONS = %w[tmux_send tmux_create tmux_close tmux_run].freeze
      OBSERVATIONS = %w[tmux_capture tmux_wait].freeze
      NAMES = (READ_ONLY + MUTATIONS + OBSERVATIONS).freeze
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
        if name == "tmux_run"
          return object({"target" => reference("pane"), "script" => mutation_text,
            "stdout_limit" => {"type" => "integer", "minimum" => 0, "maximum" => 262144},
            "stderr_limit" => {"type" => "integer", "minimum" => 0, "maximum" => 262144}}, %w[target script])
        end
        return mutation_input(name) if MUTATIONS.include?(name)
        return observation_input(name) if OBSERVATIONS.include?(name)

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

      def self.capture_limits
        {"max_lines" => {"type" => "integer", "minimum" => 1, "maximum" => 1000},
          "max_bytes" => {"type" => "integer", "minimum" => 1, "maximum" => 262144},
          "history_lines" => {"type" => "integer", "minimum" => 0, "maximum" => 1000}}
      end

      def self.observation_input(name)
        if name == "tmux_capture"
          {"oneOf" => [object(capture_limits.merge("target" => reference("pane"), "track" => {"type" => "boolean"}), ["target"]),
            object({"target" => reference("pane"), "cursor" => text.merge("pattern" => "^[a-f0-9]{32}$", "maxLength" => 32)})]}
        else
          {"oneOf" => [object(capture_limits.merge("target" => reference("pane"),
            "timeout" => {"type" => "number", "exclusiveMinimum" => 0, "maximum" => 60},
            "condition" => {"oneOf" => [object({"type" => {"const" => "screen_contains"},
              "text" => text.merge("minLength" => 1, "maxLength" => 4096)}), object({"type" => {"const" => "process_exit"}})]}), %w[target condition])]}
        end
      end

      def self.capture_output
        common = {"target" => reference("pane"), "capture_id" => text,
          "process_generation" => {"type" => ["string", "null"]},
          "encoding" => {"enum" => %w[utf-8 base64]}, "row_count" => {"type" => "integer", "minimum" => 0, "maximum" => 1000},
          "bytes" => {"type" => "integer", "minimum" => 0, "maximum" => 262144},
          "truncated" => {"type" => "boolean"}, "history_continuity" => {"const" => "unknown"},
          "interval" => object({"clock" => {"const" => "monotonic_seconds"}, "started" => {"type" => "number"}, "finished" => {"type" => "number"}}),
          "scope" => object(capture_limits), "next_cursor" => text}
        rows = {"type" => "array", "maxItems" => 1000, "items" => text}
        required = common.keys - ["next_cursor"]
        {"oneOf" => [object(common.merge("mode" => {"const" => "snapshot"}, "rows" => rows), required + %w[mode rows]),
          object(common.merge("mode" => {"const" => "delta"}, "base_capture_id" => text, "reset" => {"type" => "boolean"},
            "splice" => object({"start" => {"type" => "integer", "minimum" => 0}, "delete" => {"type" => "integer", "minimum" => 0}, "rows" => rows})),
            required + %w[mode base_capture_id reset splice next_cursor])]}
      end

      def self.wait_output
        {"oneOf" => [object({"target" => reference("pane"), "condition" => {"const" => "screen_contains"}, "capture" => capture_output}),
          object({"target" => reference("pane"), "condition" => {"const" => "process_exit"}, "process_generation" => text,
            "observed_at" => {"type" => "number"}, "exit_status" => {"const" => "unobserved"}})]}
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
        payload = if name == "tmux_run"
          object({"target" => reference("pane"), "authorization" => authorization,
            "completion" => run_completion, "stdout" => run_bytes, "stderr" => run_bytes})
        elsif MUTATIONS.include?(name)
          mutation_output(name)
        elsif name == "tmux_capture"
          capture_output
        elsif name == "tmux_wait"
          wait_output
        elsif name == "tmux_capabilities"
          object({"endpoint" => text, "server_identity" => identity,
            "enabled_tools" => {"type" => "array", "items" => text},
            "criteria_schema" => {"type" => "object"},
            "limits" => {"type" => "object", "additionalProperties" => {"type" => "number"}},
            "owns_daemon" => {"const" => false}, "resource_subscriptions" => {"const" => false},
            "authored_run" => object({"availability" => {"enum" => %w[conditional unsupported]},
              "shell_profile" => {"const" => "zsh-5.9-zle"}, "enrollment" => {"const" => "explicit_source"},
              "authorization" => {"const" => "exact_generation_at_queue_grant"},
              "stdin" => {"const" => "closed"}, "persistent_shell_changes" => {"const" => false},
              "descendant_termination" => {"const" => "unobserved"},
              "requirements" => {"type" => "array", "items" => text}}),
            "observation" => object({"screen" => {"const" => "bounded_rows"}, "history_continuity" => {"const" => "unknown"},
              "process_cursor" => {"enum" => %w[conditional unsupported]}, "requirements" => {"type" => "array", "items" => text},
              "wait_conditions" => {"type" => "array", "items" => {"enum" => %w[screen_contains process_exit]}}})})
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
            "effects" => name == "tmux_run" ? run_effects : effects}, %w[code message delivery])})]}
      end

      def self.authorization
        token = text.merge("pattern" => "^[a-f0-9]{32}$", "maxLength" => 32)
        object({"state" => {"const" => "authorized"}, "run_id" => token,
          "script_digest" => text.merge("pattern" => "^[a-f0-9]{64}$", "maxLength" => 64),
          "server_generation" => text.merge("minLength" => 1, "maxLength" => 128),
          "pane_id" => text.merge("pattern" => "^%[0-9]+$", "maxLength" => 32),
          "enrollment_generation" => token, "process_generation" => token})
      end

      def self.run_completion
        {"oneOf" => [object({"state" => {"const" => "exited"},
          "exit_status" => {"type" => "integer", "minimum" => 0, "maximum" => 255}, "signal" => {"type" => "null"}}),
          object({"state" => {"const" => "signaled"}, "exit_status" => {"type" => "null"},
            "signal" => {"type" => "integer", "minimum" => 1, "maximum" => 255}})]}
      end

      def self.run_bytes
        object({"encoding" => {"enum" => %w[utf-8 base64]}, "data" => text.merge("maxLength" => 349528),
          "bytes" => {"type" => "integer", "minimum" => 0, "maximum" => 262144}, "truncated" => {"const" => false}})
      end

      def self.run_effects
        object({"state" => {"enum" => %w[none known unknown]},
          "authorization" => {"oneOf" => [authorization, {"type" => "null"}]},
          "completion" => {"oneOf" => [object({"state" => {"const" => "unobserved"}}), *run_completion.fetch("oneOf")]}})
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
        if name == "tmux_run"
          "Run an authored POSIX script in an explicitly enrolled idle, empty zsh 5.9 editor. Opt-in; no terminal injection. Exact queue authorization binds the existing shell generation; execution may follow a later pane replacement without retargeting it. Inherits cwd/exported environment, closed stdin, separate bounded UTF-8/base64 outputs. Defaults: 65536 bytes per output, 65536 script bytes; overflow refuses completion. Reports native exit/signal only from the helper; cancellation never proves descendants stopped."
        elsif name == "tmux_capture"
          "Read exact-pane screen/history rows preserving LF. Defaults: 200 lines, 65536 bytes, zero history lines, track=false. Limits: 1000 lines/history, 262144 bytes. UTF-8 or base64; truncation is separate from unknown history continuity. Tracked process cursors require tmux>=3.3 and a native process identity backend: Linux peer pidfds with matching PID namespaces, or Darwin kqueue process observation. Continuation returns an exact state row splice, not a live-output journal. Refuses capture after-hooks."
        elsif name == "tmux_wait"
          "Wait for observed literal screen text or the initial pane process exit. Deadline in seconds is capped by the application limit. Uses control events/process descriptors; no polling. Requires tmux>=3.3 and Linux peer pidfds with matching PID namespaces or Darwin kqueue process observation. Reports observed evidence, never remote termination caused by cancellation or an inferred process exit status."
        elsif name == "tmux_send"
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
