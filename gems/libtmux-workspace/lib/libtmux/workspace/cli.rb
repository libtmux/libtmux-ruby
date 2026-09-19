# frozen_string_literal: true

require "libtmux/workspace"
require "optparse"

module LibTmux
  class Workspace
    class CLI
      def self.run(arguments, out: $stdout, err: $stderr, directory: Dir.pwd, environment: ENV)
        new(arguments, out, err, directory, environment).run
      end

      def initialize(arguments, out, err, directory, environment)
        @arguments, @out, @err, @directory, @environment = arguments.dup, out, err, directory, environment
        @json = @arguments.include?("--json")
        @options = {timeout: 5.0, environment: {}, expand_environment: false, compensate: false}
      end
      private_class_method :new

      def run
        return help if @arguments == ["--help"] || @arguments == ["-h"]

        command = @arguments.shift
        raise ArgumentError unless %w[validate plan load].include?(command)

        @arguments.take_while { |argument| argument != "--" }.each_with_index do |argument, index|
          next unless argument == "--switch"
          value = @arguments[index + 1]
          raise OptionParser::MissingArgument, "--switch" if !value || value.start_with?("-")
        end
        parser.parse!(@arguments)
        return help if @options[:help]

        validate_arguments(command)
        file = configuration_file
        workspace = Workspace.load(file, expand_environment: @options.fetch(:expand_environment), environment: @options.fetch(:environment))
        case command
        when "validate"
          emit({"valid" => true, "profile" => PROFILE, "version" => CONFIG_VERSION}, "Workspace configuration is valid.")
        when "plan"
          if @options[:live]
            plan = with_server { |server| workspace.plan(snapshot: server.snapshot(timeout: @options.fetch(:timeout))) }
            emit(plan.to_h, human_plan(plan))
          else
            plan = workspace.plan
            emit(plan.to_h, human_plan(plan))
          end
        when "load"
          with_server do |server|
            @result = workspace.plan.apply(server: server, timeout: @options.fetch(:timeout), compensate: @options.fetch(:compensate))
            if @options[:switch]
              server.switch_client(client: @options.fetch(:switch), session: @result.created_refs.fetch("session"),
                timeout: @options.fetch(:timeout))
            end
            if @options[:attach]
              File.open("/dev/tty", "r+") do |terminal|
                result = server.attach(session: @result.created_refs.fetch("session"), terminal: terminal, term: @environment.fetch("TERM"))
                raise TransportError.new("attached terminal client failed", phase: :terminal) unless result.success?
              end
            end
          end
          emit(@result.to_h, "Workspace created; #{@result.completed_steps.length} steps completed. Shell commands were dispatched.")
        end
        0
      rescue Workspace::ConfigError => error
        report(error, kind: "configuration", status: 2)
      rescue Workspace::ApplyError => error
        @result = error.result
        interrupted = ["Interrupt", "LibTmux::Cancelled"].include?(error.failure_class)
        status = interrupted ? 130 : (@result.uncertain? || !@result.effects.empty? ? 3 : 1)
        report(error, kind: interrupted ? "interrupted" : "application", status: status)
      rescue OptionParser::ParseError, ArgumentError, KeyError
        report(nil, kind: "arguments", status: @result ? 3 : 2)
      rescue Interrupt, LibTmux::Cancelled => error
        report(error, kind: "interrupted", status: 130)
      rescue LibTmux::Error, SystemCallError, IOError => error
        report(error, kind: "execution", status: @result ? 3 : 1)
      end

      private

      def parser
        @parser ||= OptionParser.new do |options|
          options.banner = "Usage: libtmux-workspace validate|plan|load [options] [FILE]"
          options.on("--json", "Write structured JSON to stdout") { @json = true }
          options.on("--socket PATH", "Explicit existing tmux socket for load or plan --live") { |value| @options[:socket] = value }
          options.on("--live", "Acquire a snapshot before planning") { @options[:live] = true }
          options.on("--timeout SECONDS", Float, "Per-operation apply/capture/switch deadline (default: 5)") { |value| @options[:timeout] = value }
          options.on("--compensate", "Attempt guarded cleanup of positively created resources on failure") { @options[:compensate] = true }
          options.on("--attach", "Attach this CLI terminal after successful load") { @options[:attach] = true }
          options.on("--switch CLIENT", "Switch the explicit current client after successful load") { |value| @options[:switch] = value }
          options.on("--expand-environment", "Expand ${NAME} in paths/environment using explicit --env values") { @options[:expand_environment] = true }
          options.on("--env NAME=VALUE", "Add an explicit expansion value; shell command text is unchanged") do |value|
            name, contents = value.split("=", 2)
            raise ArgumentError unless contents && /\A[A-Za-z_][A-Za-z0-9_]*\z/.match?(name)
            raise ArgumentError if @options.fetch(:environment).key?(name)

            @options.fetch(:environment)[name] = contents
          end
          options.on("-h", "--help", "Show supported commands and options") { @options[:help] = true }
        end
      end

      def help
        @out.puts(parser)
        0
      end

      def validate_arguments(command)
        raise ArgumentError if @arguments.length > 1
        raise ArgumentError unless @options.fetch(:timeout).finite? && @options.fetch(:timeout).positive?
        raise ArgumentError if @options[:attach] && @options[:switch]
        if @options[:switch]
          client = @options.fetch(:switch)
          raise ArgumentError unless client.bytesize.between?(1, 1024) && !client.b.include?("\0")
        end
        raise ArgumentError if command != "load" && (@options[:attach] || @options[:switch] || @options[:compensate])
        raise ArgumentError if @options[:live] && command != "plan"
        live = command == "load" || @options[:live]
        raise ArgumentError if live && (!@options[:socket].is_a?(String) || @options[:socket].empty?)
        raise ArgumentError if !live && @options[:socket]
        if @options[:attach]
          term = @environment["TERM"]
          raise ArgumentError unless term.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9_.+-]{0,127}\z/.match?(term)
        end
      end

      def configuration_file
        return File.expand_path(@arguments.first, @directory) if @arguments.first

        candidates = %w[.tmuxp.yaml .tmuxp.yml .tmuxp.json].map { |name| File.join(@directory, name) }.select { |path| File.exist?(path) }
        unless candidates.length == 1
          @argument_message = "Provide a configuration file; discovery requires exactly one .tmuxp.yaml, .tmuxp.yml or .tmuxp.json."
          raise ArgumentError
        end
        candidates.first
      end

      def with_server(&block)
        LibTmux::Server.open(socket_path: File.expand_path(@options.fetch(:socket), @directory), &block)
      end

      def human_plan(plan)
        (["#{plan.mode}: #{plan.steps.length} ordered steps"] +
          plan.steps.map { |step| "#{step.id}. #{step.operation} #{step.target} (#{step.effect})" }).join("\n")
      end

      def emit(value, human)
        @out.puts(@json ? JSON.generate(value) : human)
      end

      def report(error, kind:, status:)
        message = if kind == "arguments"
          @argument_message || "Invalid arguments; use --help for supported options."
        elsif error.is_a?(Workspace::ConfigError) || error.is_a?(Workspace::ApplyError)
          error.message
        else
          "Workspace #{kind} failed#{error ? " (#{error.class})" : ''}."
        end
        value = {"error" => {"kind" => kind, "message" => message, "exit_status" => status}}
        if error.is_a?(LibTmux::Error)
          value.fetch("error")["delivery"] = error.delivery.to_s
          value.fetch("error")["phase"] = error.phase&.to_s
        end
        value.fetch("error")["failure_class"] = error.failure_class if error.is_a?(Workspace::ApplyError)
        value["result"] = @result.to_h if @result
        if @json
          @out.puts(JSON.generate(value))
        else
          @err.puts(message)
          @err.puts(JSON.generate(@result.to_h)) if @result
        end
        status
      end
    end
  end
end
