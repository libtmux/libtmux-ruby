# frozen_string_literal: true

require "libtmux"
require "json"
require "psych"
require "libtmux/workspace/version"

module LibTmux
  class Workspace
    PROFILE = "libtmux-ruby.workspace"
    CONFIG_VERSION = 1
    LIMITS = {max_bytes: 1 << 20, max_depth: 32, max_nodes: 10_000,
      max_string_bytes: 1 << 16, max_windows: 128, max_panes: 1024}.freeze
    private_constant :LIMITS

    class ConfigError < LibTmux::Error
      def initialize(message = "invalid workspace configuration", path: "$", expected: nil)
        super("#{message} at #{path}#{expected ? "; expected #{expected}" : ''}", path: path, expected: expected, phase: :workspace)
      end
    end
    class ConflictError < LibTmux::Error; end

    def self.load(path, format: nil, **options)
      unless path.is_a?(String) && !path.empty? && !path.include?("\0")
        raise ArgumentError, "workspace path must be a nonempty String without NUL"
      end
      filename = File.expand_path(path)
      format ||= case File.extname(filename).downcase
      when ".json" then :json
      when ".yaml", ".yml" then :yaml
      else raise ConfigError.new("workspace file format is unknown", expected: "JSON/YAML extension or explicit format")
      end
      limit = options.fetch(:max_bytes, LIMITS.fetch(:max_bytes))
      raise ArgumentError, "workspace byte limit must be a positive integer" unless limit.is_a?(Integer) && limit.positive?

      bytes = File.open(filename, File::RDONLY | File::NONBLOCK) do |file|
        raise ConfigError.new("invalid workspace file", expected: "regular configuration file") unless file.stat.file?
        file.binmode
        file.read(limit + 1) || ""
      end
      parse(bytes, format: format, base_directory: File.dirname(filename), **options)
    rescue SystemCallError
      raise ConfigError.new("workspace file could not be read", expected: "readable configuration file"), cause: nil
    end

    def self.parse(bytes, format:, base_directory:, expand_environment: false, environment: {}, **limits)
      unless (limits.keys - LIMITS.keys).empty? && limits.values.all? { |value| value.is_a?(Integer) && value.positive? }
        raise ArgumentError, "workspace limits must be known positive integers"
      end
      bounds = LIMITS.merge(limits).freeze
      document = Document.new(bounds).parse(bytes, format)
      config = Normalizer.new(base_directory, expand_environment, environment, bounds).normalize(document)
      if JSON.generate(config).bytesize > bounds.fetch(:max_bytes)
        raise ConfigError.new("normalized workspace exceeds its wire byte limit", expected: "bounded canonical JSON")
      end
      Document.new(bounds).validate_tree(config)
      new(config)
    end

    def initialize(config)
      @config = config
      freeze
    end
    private_class_method :new

    def to_h
      @config
    end

    def plan(snapshot: nil)
      Plan.new(self, snapshot: snapshot)
    end

    def inspect
      "#<#{self.class} profile=#{PROFILE} version=#{CONFIG_VERSION} windows=#{@config.fetch('windows').length}>"
    end
  end
end

require "libtmux/workspace/document"
require "libtmux/workspace/normalizer"
require "libtmux/workspace/plan"
require "libtmux/workspace/apply"
