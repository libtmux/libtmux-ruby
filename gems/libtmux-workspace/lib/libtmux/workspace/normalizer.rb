# frozen_string_literal: true

module LibTmux
  class Workspace
    class Normalizer
      COMMON = %w[start_directory environment shell_command shell_command_before].freeze
      ROOT = (COMMON + %w[profile version session_name windows options window_options]).freeze
      WINDOW = (COMMON + %w[window_name window_index panes focus layout options]).freeze
      PANE = (COMMON + %w[focus split size]).freeze
      LAYOUTS = %w[even-horizontal even-vertical main-horizontal main-vertical tiled].freeze
      SESSION_OPTIONS = {"base-index" => :index, "status" => :boolean, "mouse" => :boolean,
        "renumber-windows" => :boolean, "history-limit" => :index,
        "status-interval" => :index, "status-position" => %w[top bottom],
        "status-justify" => %w[left centre right absolute-centre],
        "default-terminal" => :unsupported}.freeze
      WINDOW_OPTIONS = {"automatic-rename" => :boolean, "allow-rename" => :boolean,
        "remain-on-exit" => :boolean, "synchronize-panes" => :boolean,
        "aggressive-resize" => :boolean, "pane-base-index" => :pane_index,
        "main-pane-width" => :index, "main-pane-height" => :index,
        "window-status-format" => :text, "window-status-current-format" => :text,
        "pane-border-status" => %w[off top bottom]}.freeze
      private_constant :COMMON, :ROOT, :WINDOW, :PANE, :LAYOUTS, :SESSION_OPTIONS, :WINDOW_OPTIONS

      def initialize(base, expand, environment, limits)
        @limits, @expand, @expanded_bytes = limits, expand, 0
        @normalized_bytes, @normalized_nodes = 0, 0
        unless base.is_a?(String) && !base.empty? && !base.include?("\0")
          raise ArgumentError, "workspace base_directory must be a nonempty String without NUL"
        end
        unless expand.equal?(true) || expand.equal?(false)
          raise ArgumentError, "expand_environment must be Boolean"
        end
        @base = File.expand_path(base)
        @environment = environment_map(environment, "$environment", expand: false)
        @pane_count = 0
      end

      def normalize(input)
        object(input, ROOT, "$")
        if input.key?("profile") || input.key?("version")
          unless input["profile"] == PROFILE && input["version"].is_a?(Integer) && input["version"] == CONFIG_VERSION
            fail_at("$", "#{PROFILE} version #{CONFIG_VERSION}, with both envelope fields")
          end
        end
        name = name(input.fetch("session_name") { fail_at("$.session_name", "session name") }, "$.session_name")
        root = common(input, {"start_directory" => @base, "environment" => {},
          "shell_command_before" => [], "shell_command" => []}, "$")
        root_options = options(input.fetch("options", {}), SESSION_OPTIONS, "$.options")
        inherited_options = options(input.fetch("window_options", {}), WINDOW_OPTIONS, "$.window_options")
        windows = input["windows"]
        unless windows.is_a?(Array) && windows.length.between?(1, @limits.fetch(:max_windows))
          fail_at("$.windows", "nonempty bounded window array")
        end
        indexes, explicit = {}, {}
        windows.each_with_index do |window, position|
          path = "$.windows[#{position}]"
          object(window, WINDOW, path)
          next unless window.key?("window_index")

          value = index(window["window_index"], "#{path}.window_index")
          fail_at("#{path}.window_index", "unique window index") if explicit.key?(value)
          explicit[value] = true
        end
        next_index = root_options.fetch("base-index", 0)
        normalized = windows.each_with_index.map do |window, position|
          path = "$.windows[#{position}]"
          if window.key?("window_index")
            assigned = window.fetch("window_index")
          else
            next_index += 1 while explicit.key?(next_index) || indexes.key?(next_index)
            assigned = index(next_index, "#{path}.window_index")
            next_index += 1
          end
          indexes[assigned] = true
          normalize_window(window, root, inherited_options, assigned, path)
        end
        choose_focus(normalized, "$.windows")
        # Canonical exports carry commands only at leaves. Reloading must not
        # prepend already inherited commands a second time.
        root["shell_command_before"] = []
        root["shell_command"] = []
        normalized.each do |window|
          window["shell_command_before"] = []
          window["shell_command"] = []
        end
        freeze_tree(root.merge("profile" => PROFILE, "version" => CONFIG_VERSION,
          "session_name" => name, "options" => root_options,
          "window_options" => inherited_options, "windows" => normalized))
      end

      private

      def normalize_window(input, parent, inherited_options, assigned, path)
        value = common(input, parent, path)
        value["window_name"] = name(input.fetch("window_name") { fail_at("#{path}.window_name", "window name") }, "#{path}.window_name")
        value["window_index"] = assigned
        value["focus"] = boolean(input.fetch("focus", false), "#{path}.focus")
        value["options"] = inherited_options.merge(options(input.fetch("options", {}), WINDOW_OPTIONS, "#{path}.options"))
        layout = input["layout"]
        fail_at("#{path}.layout", "supported named layout") if input.key?("layout") && !LAYOUTS.include?(layout)
        value["layout"] = layout if layout
        panes = input["panes"]
        fail_at("#{path}.panes", "nonempty pane array") unless panes.is_a?(Array) && !panes.empty?
        @pane_count += panes.length
        fail_at("#{path}.panes", "bounded total pane count") if @pane_count > @limits.fetch(:max_panes)
        value["panes"] = panes.each_with_index.map do |pane, position|
          child_path = "#{path}.panes[#{position}]"
          pane = {"shell_command" => pane} if pane.is_a?(String)
          object(pane, PANE, child_path)
          child = common(pane, value, child_path)
          child["focus"] = boolean(pane.fetch("focus", false), "#{child_path}.focus")
          if position.zero? && (pane.key?("split") || pane.key?("size"))
            fail_at(child_path, "split geometry only for subsequent panes")
          end
          direction = pane.fetch("split", "vertical")
          fail_at("#{child_path}.split", "horizontal or vertical") unless %w[horizontal vertical].include?(direction)
          child["split"] = direction unless position.zero?
          if pane.key?("size")
            size = pane["size"]
            valid = (size.is_a?(Integer) && size.between?(1, (1 << 31) - 1)) ||
              (size.is_a?(String) && /\A(?:[1-9]|[1-9][0-9])%\z/.match?(size))
            fail_at("#{child_path}.size", "positive cell count or percentage between 1% and 99%") unless valid
            fail_at("#{child_path}.size", "split size without a final named layout") if layout
            child["size"] = size
          end
          child
        end
        choose_focus(value["panes"], "#{path}.panes")
        value
      end

      def common(input, parent, path)
        directory = if input.key?("start_directory")
          value = expand(text(input["start_directory"], "#{path}.start_directory", empty: false), "#{path}.start_directory")
          # Prefixing relative paths avoids File.expand_path's ambient ~ expansion.
          File.expand_path(value.start_with?(File::SEPARATOR) ? value : File.join(@base, value))
        else parent.fetch("start_directory")
        end
        inherited_environment = parent.fetch("environment").merge(environment_map(input.fetch("environment", {}), "#{path}.environment"))
        before = parent.fetch("shell_command_before") + commands(input.fetch("shell_command_before", []), "#{path}.shell_command_before")
        command = input.key?("shell_command") ? commands(input["shell_command"], "#{path}.shell_command") : parent.fetch("shell_command")
        result = {"start_directory" => directory, "environment" => inherited_environment,
          "shell_command_before" => before, "shell_command" => command}
        account(result, path)
        result
      end

      def object(value, allowed, path)
        fail_at(path, "configuration object") unless value.is_a?(Hash)
        unknown = value.keys - allowed
        unless unknown.empty?
          known_unsupported = %w[before_script plugins hooks erb callback callbacks].find { |key| unknown.include?(key) }
          failure_path = known_unsupported ? "#{path}.#{known_unsupported}" : path
          fail_at(failure_path, "supported data-only fields; move callbacks or hooks into explicit application code")
        end
      end

      def environment_map(value, path, expand: @expand)
        fail_at(path, "environment object") unless value.is_a?(Hash)
        fail_at(path, "bounded environment map") if value.length > @limits.fetch(:max_nodes)
        bytes = 0
        value.to_h do |key, item|
          unless key.is_a?(String) && /\A[A-Za-z_][A-Za-z0-9_]*\z/.match?(key)
            fail_at(path, "portable environment variable names")
          end
          item = text(item, path)
          bytes += key.bytesize + item.bytesize
          fail_at(path, "bounded environment bytes") if bytes > @limits.fetch(:max_bytes)
          [key.dup, expand ? self.expand(item, path) : item]
        end
      end

      def expand(value, path)
        return value unless @expand

        output, offset = +"", 0
        append = lambda do |chunk|
          fail_at(path, "bounded expanded value") if output.bytesize + chunk.bytesize > @limits.fetch(:max_string_bytes)
          output << chunk
        end
        value.scan(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/) do
          match = Regexp.last_match
          append.call(value[offset...match.begin(0)])
          replacement = @environment.fetch(match[1]) { fail_at(path, "explicit substitution value for every variable") }
          append.call(replacement)
          offset = match.end(0)
        end
        append.call(value[offset..])
        @expanded_bytes += output.bytesize
        if output.bytesize > @limits.fetch(:max_string_bytes) || @expanded_bytes > @limits.fetch(:max_bytes)
          fail_at(path, "bounded expanded values")
        end
        output
      end

      def account(value, path)
        @normalized_nodes += 1
        fail_at(path, "bounded normalized node count") if @normalized_nodes > @limits.fetch(:max_nodes)
        case value
        when Hash then value.each { |key, child| account(key, path); account(child, path) }
        when Array then value.each { |child| account(child, path) }
        when String
          @normalized_bytes += value.bytesize
          fail_at(path, "bounded normalized bytes") if @normalized_bytes > @limits.fetch(:max_bytes)
        end
      end

      def text(value, path, empty: true)
        fail_at(path, "UTF-8 text") unless value.is_a?(String)
        result = value.dup.force_encoding(Encoding::UTF_8)
        unless result.valid_encoding? && !result.include?("\0") && (empty || !result.empty?) && result.bytesize <= @limits.fetch(:max_string_bytes)
          fail_at(path, "bounded UTF-8 text without NUL")
        end
        result
      end

      def name(value, path)
        result = text(value, path, empty: false)
        unless !result.match?(/[\x00-\x1f\x7f:.]/) && !result.strip.empty?
          fail_at(path, "name without controls, colon or period")
        end
        result
      end

      def commands(value, path)
        value = [value] if value.is_a?(String)
        fail_at(path, "shell command string or ordered string array") unless value.is_a?(Array)
        fail_at(path, "bounded command array") if value.length > @limits.fetch(:max_nodes)
        value.map { |command| text(command, path) }
      end

      def boolean(value, path)
        fail_at(path, "Boolean") unless value.equal?(true) || value.equal?(false)
        value
      end

      def index(value, path, maximum = (1 << 31) - 1)
        fail_at(path, "integer index from zero through #{maximum}") unless value.is_a?(Integer) && value.between?(0, maximum)
        value
      end

      def options(value, catalog, path)
        fail_at(path, "typed option object") unless value.is_a?(Hash)
        value.to_h do |key, item|
          type = catalog[key]
          fail_at(path, "supported options for this scope") unless type && type != :unsupported
          converted = case type
          when :boolean then boolean(item, "#{path}.#{key}")
          when :index then index(item, "#{path}.#{key}")
          when :pane_index then index(item, "#{path}.#{key}", 65535)
          when :text then text(item, "#{path}.#{key}")
          else
            fail_at("#{path}.#{key}", "declared option choice") unless type.include?(item)
            item.dup
          end
          [key.dup, converted]
        end
      end

      def choose_focus(values, path)
        focused = values.count { |item| item.fetch("focus") }
        fail_at(path, "at most one focused item") if focused > 1
        values.first["focus"] = true if focused.zero?
      end

      def freeze_tree(value)
        case value
        when Hash then value.to_h { |key, item| [key.dup.freeze, freeze_tree(item)] }.freeze
        when Array then value.map { |item| freeze_tree(item) }.freeze
        when String then value.dup.freeze
        else value
        end
      end

      def fail_at(path, expected)
        raise ConfigError.new(path: path, expected: expected)
      end
    end
    private_constant :Normalizer
  end
end
