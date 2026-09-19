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
          max_output_bytes: 1 << 22, max_response_bytes: 1 << 20,
          enrollments: [], enrollment_timeout: 60.0}
        @setup_files, @enrollment_tasks = [], []
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
          rescue Interrupt, LibTmux::Cancelled => error
            report("MCP interrupted; dispatched effects may remain.", 130, failure: error)
          rescue StandardError => error
            report("MCP execution failed (#{error.class}); dispatched effects may remain.", 1, failure: error)
          end
        end.wait
      rescue OptionParser::ParseError, ArgumentError => error
        report("Invalid arguments; use --help for supported options.", 2, failure: error)
      rescue Interrupt, LibTmux::Cancelled => error
        report("MCP interrupted; dispatched effects may remain.", 130, failure: error)
      rescue StandardError => error
        report("MCP startup failed (#{error.class}).", 1, failure: error)
      end

      private

      def serve(endpoint, task)
        Server.open(endpoint: endpoint) do |server|
          LibTmux::Async.open(server: server, parent: task) do |scope|
            app = Application.new(server: scope.server, endpoint_name: @options.fetch(:endpoint_name),
              enabled_tools: @options.fetch(:tools).uniq, request_timeout: @options.fetch(:timeout),
              max_response_bytes: @options.fetch(:max_response_bytes))
            failure = transport = nil
            begin
              prepare_enrollments(app, scope.server, task)
              transport = StdioTransport.new(server: app.sdk_server, parent: task, input: @input, output: @output,
                concurrency: @options.fetch(:concurrency), max_requests: @options.fetch(:max_requests),
                max_frame_bytes: @options.fetch(:max_frame_bytes), max_output_bytes: @options.fetch(:max_output_bytes),
                request_timeout: @options.fetch(:timeout))
              transport.run
            rescue Exception => error
              failure = error
            ensure
              [-> { transport&.close }, -> { close_enrollments }, -> { app.close }].each do |cleanup|
                begin
                  cleanup.call
                rescue Exception => error
                  if failure
                    ProcessIdentity.attach_cleanup(failure, ["MCP cleanup failed (#{error.class})"])
                    diagnostic("MCP cleanup also failed (#{error.class}).", failure: failure)
                  end
                  failure ||= error
                end
              end
            end
            raise failure if failure
          end
        end
      end

      def prepare_enrollments(app, server, task)
        return if @options.fetch(:enrollments).empty?

        panes = server.list_panes(timeout: @options.fetch(:timeout)).to_h { |pane| [pane.id, pane.ref] }
        @options.fetch(:enrollments).each do |id, path|
          reference = panes[id]
          raise TargetNotFoundError.new("enrollment pane does not exist", phase: :admission) unless reference

          invitation = app.invite_shell(reference, timeout: @options.fetch(:timeout),
            expires_in: @options.fetch(:enrollment_timeout))
          arguments = invitation.shell_arguments.map do |value|
            raise ArgumentError if value.include?("\0") || value.include?("\n") || value.include?("\r")

            "'#{value.gsub("'") { %q('\'') }}'"
          end
          owned = publish_setup_file(path, "source #{arguments.join(' ')}\n")
          child = ::Async::Task.new(task) do
            begin
              app.accept_shell(invitation)
            rescue LibTmux::Cancelled, ::Async::Cancel => error
              diagnostic("Shell enrollment was cancelled.", failure: error) unless @enrollment_stopping
            rescue StandardError => error
              diagnostic("Shell enrollment failed (#{error.class}).", failure: error) unless @enrollment_stopping
            ensure
              remove_setup_file(owned)
            end
          end
          @enrollment_tasks << child
          child.run
        end
      end

      def publish_setup_file(path, command)
        temporary = File.join(File.dirname(path), ".libtmux-ruby-shell-#{SecureRandom.hex(16)}")
        owned = staging = nil
        Thread.handle_interrupt(Exception => :never) do
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            staging = [temporary, file.stat]
            @setup_files << staging
            file.chmod(0o600)
            file.write(command)
          end
          # A hard link publishes the complete file and refuses existing names.
          File.link(temporary, path)
          owned = [path, staging.last]
          @setup_files << owned
        end
        remove_setup_file(staging)
        owned
      end

      def remove_setup_file(owned)
        path, identity = owned
        begin
          current = File.lstat(path)
          File.unlink(path) if [current.dev, current.ino] == [identity.dev, identity.ino]
        rescue Errno::ENOENT
          nil
        end
        @setup_files.delete(owned)
      end

      def close_enrollments
        @enrollment_stopping = true
        errors = []
        interrupted = nil
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
        actions = @enrollment_tasks.map do |child|
          lambda do
            child.cancel unless child.finished?
            child.wait(timeout: [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
          end
        end
        actions.concat(@setup_files.dup.map { |owned| -> { remove_setup_file(owned) } })
        actions.each do |action|
          begin
            action.call
          rescue ::Async::Cancel => error
            interrupted ||= error
            retry if Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            errors << "shell setup retirement was interrupted"
          rescue Exception => error
            errors << "shell setup retirement failed (#{error.class})"
          end
        end
        @enrollment_tasks.reject!(&:finished?)
        errors << "shell enrollment tasks remain active" unless @enrollment_tasks.empty?
        if interrupted
          ProcessIdentity.attach_cleanup(interrupted, errors) unless errors.empty?
          raise interrupted
        end
        raise TransportError.new("shell setup cleanup remains pending", phase: :retire, cleanup_errors: errors) unless errors.empty?

        nil
      end

      def parser
        @parser ||= OptionParser.new do |options|
          options.banner = "Usage: libtmux-mcp (--socket PATH | --socket-name NAME) [options]"
          options.on("--socket PATH", "Borrow this existing tmux Unix socket") { |value| @options[:socket_path] = value }
          options.on("--socket-name NAME", "Borrow this explicit tmux socket name") { |value| @options[:socket_name] = value }
          options.on("--endpoint NAME", "Public endpoint alias (default: local)") { |value| @options[:endpoint_name] = value }
          options.on("--tmux EXECUTABLE", "Resolve and pin this tmux executable at startup") { |value| @options[:executable] = value }
          options.on("--enable-tool NAME", "Enable one additional tool; repeat as needed") { |value| @options.fetch(:tools) << value }
          options.on("--enroll-pane %ID=FILE", "Write a private zsh setup file for this exact pane; requires tmux_run") do |value|
            id, path = value.split("=", 2)
            raise ArgumentError unless id && /\A%\d+\z/.match?(id) && path && !path.empty? && path.bytesize <= 4096 && !/[\0\r\n]/.match?(path)

            @options.fetch(:enrollments) << [id.freeze, File.expand_path(path).freeze].freeze
          end
          options.on("--enrollment-timeout SECONDS", Float, "Setup file lifetime, at most 300 seconds (default: 60)") { |value| @options[:enrollment_timeout] = value }
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
        lifetime = @options.fetch(:enrollment_timeout)
        raise ArgumentError unless lifetime.finite? && lifetime.positive? && lifetime <= 300
        enrollments = @options.fetch(:enrollments)
        raise ArgumentError unless enrollments.length <= 8
        raise ArgumentError unless enrollments.map(&:first).uniq.length == enrollments.length && enrollments.map(&:last).uniq.length == enrollments.length
        raise ArgumentError if !enrollments.empty? && !@options.fetch(:tools).include?("tmux_run")
        %i[concurrency max_requests max_frame_bytes max_output_bytes max_response_bytes].each do |key|
          raise ArgumentError unless @options.fetch(key).positive?
        end
        raise ArgumentError unless [@input, @output].all? { |io| io.is_a?(IO) && !io.closed? }
      end

      def report(message, status, failure: nil)
        diagnostic(message, failure: failure)
        status
      end

      def diagnostic(message, failure: nil)
        @error.puts(message)
      rescue Exception => error
        ProcessIdentity.attach_cleanup(failure, ["MCP diagnostic failed (#{error.class})"]) if failure
        nil
      end
    end
  end
end
