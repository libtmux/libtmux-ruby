# frozen_string_literal: true

require "libtmux/mcp"
require "optparse"

module LibTmux
  module MCP
    class CLI
      def self.run(arguments, input: $stdin, out: $stdout, err: $stderr)
        new(arguments, input, out, err).run
      end

      def initialize(arguments, input, output, error)
        @arguments, @input, @output, @error = arguments.dup, input, output, error
        @options = {endpoint_name: "local", executable: "tmux", tools: Catalog::READ_ONLY.dup,
          timeout: 5.0, concurrency: 4, max_requests: 32, max_frame_bytes: 1 << 20,
          max_output_bytes: 1 << 22, max_response_bytes: 1 << 20}
      end
      private_class_method :new

      def run
        parser.parse!(@arguments)
        if @options[:help] || @options[:version]
          @output.puts(@options[:help] ? parser : VERSION)
          return 0
        end
        validate_arguments
        endpoint = Endpoint.new(socket_path: @options[:socket_path], socket_name: @options[:socket_name],
          executable: @options.fetch(:executable))
        Async do |task|
          begin
            serve(endpoint, task)
            0
          rescue Interrupt, LibTmux::Cancelled
            report("MCP interrupted; dispatched effects may remain.", 130)
          rescue StandardError => error
            report("MCP execution failed (#{error.class}); dispatched effects may remain.", 1)
          end
        end.wait
      rescue OptionParser::ParseError, ArgumentError
        report("Invalid arguments; use --help for supported options.", 2)
      rescue Interrupt, LibTmux::Cancelled
        report("MCP interrupted; dispatched effects may remain.", 130)
      rescue StandardError => error
        report("MCP startup failed (#{error.class}).", 1)
      end

      private

      def serve(endpoint, task)
        Server.open(endpoint: endpoint) do |server|
          LibTmux::Async.open(server: server, parent: task) do |scope|
            app = Application.new(server: scope.server, endpoint_name: @options.fetch(:endpoint_name),
              enabled_tools: @options.fetch(:tools).uniq, request_timeout: @options.fetch(:timeout),
              max_response_bytes: @options.fetch(:max_response_bytes))
            transport = StdioTransport.new(server: app.sdk_server, parent: task, input: @input, output: @output,
              concurrency: @options.fetch(:concurrency), max_requests: @options.fetch(:max_requests),
              max_frame_bytes: @options.fetch(:max_frame_bytes), max_output_bytes: @options.fetch(:max_output_bytes),
              request_timeout: @options.fetch(:timeout))
            failure = nil
            begin
              transport.run
            rescue Exception => error
              failure = error
            ensure
              begin
                transport.close
              rescue Exception => cleanup
                @error.puts("MCP cleanup also failed (#{cleanup.class}).") if failure
                failure ||= cleanup
              end
            end
            raise failure if failure
          end
        end
      end

      def parser
        @parser ||= OptionParser.new do |options|
          options.banner = "Usage: libtmux-mcp (--socket PATH | --socket-name NAME) [options]"
          options.on("--socket PATH", "Borrow this existing tmux Unix socket") { |value| @options[:socket_path] = value }
          options.on("--socket-name NAME", "Borrow this explicit tmux socket name") { |value| @options[:socket_name] = value }
          options.on("--endpoint NAME", "Public endpoint alias (default: local)") { |value| @options[:endpoint_name] = value }
          options.on("--tmux EXECUTABLE", "Resolve and pin this tmux executable at startup") { |value| @options[:executable] = value }
          options.on("--enable-tool NAME", "Enable one additional tool; repeat as needed") { |value| @options.fetch(:tools) << value }
          options.on("--timeout SECONDS", Float, "Total request deadline (default: 5)") { |value| @options[:timeout] = value }
          options.on("--concurrency COUNT", Integer, "Active requests (default: 4)") { |value| @options[:concurrency] = value }
          options.on("--max-requests COUNT", Integer, "Active plus waiting requests (default: 32)") { |value| @options[:max_requests] = value }
          options.on("--max-frame-bytes BYTES", Integer, "Input frame limit (default: 1048576)") { |value| @options[:max_frame_bytes] = value }
          options.on("--max-output-bytes BYTES", Integer, "Queued protocol output limit (default: 4194304)") { |value| @options[:max_output_bytes] = value }
          options.on("--max-response-bytes BYTES", Integer, "Structured tool response limit (default: 1048576)") { |value| @options[:max_response_bytes] = value }
          options.on("--version", "Print the gem version") { @options[:version] = true }
          options.on("-h", "--help", "Show supported options") { @options[:help] = true }
        end
      end

      def validate_arguments
        raise ArgumentError unless @arguments.empty?
        raise ArgumentError unless [@options[:socket_path], @options[:socket_name]].compact.length == 1
        raise ArgumentError unless @options.fetch(:tools).all? { |name| Catalog::NAMES.include?(name) }
        raise ArgumentError unless /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(@options.fetch(:endpoint_name))
        raise ArgumentError unless @options.fetch(:timeout).finite? && @options.fetch(:timeout).positive?
        %i[concurrency max_requests max_frame_bytes max_output_bytes max_response_bytes].each do |key|
          raise ArgumentError unless @options.fetch(key).positive?
        end
        raise ArgumentError unless [@input, @output].all? { |io| io.is_a?(IO) && !io.closed? }
      end

      def report(message, status)
        @error.puts(message)
        status
      end
    end
  end
end
