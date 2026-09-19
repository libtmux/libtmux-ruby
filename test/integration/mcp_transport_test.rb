# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux/mcp"
require "libtmux/mcp/stdio_transport"

class MCPTransportTest < Minitest::Test
  def test_sdk_modern_and_handshake_lifecycles_keep_envelopes_and_state_separate
    Async do |parent|
      %w[2024-11-05 2025-03-26 2025-06-18 2025-11-25].each do |version|
        with_transport(parent) do |transport, input, output|
          send_frame(input, request(1, "initialize", protocolVersion: version, capabilities: {}, clientInfo: {name: "legacy", version: "1"}))
          assert_equal version, read_frame(parent, output).dig("result", "protocolVersion")
          send_frame(input, {jsonrpc: "2.0", method: "notifications/initialized"})
          send_frame(input, request(2, "custom/echo", value: "legacy"))
          response = read_frame(parent, output)
          assert_equal "legacy", response.dig("result", "value")
          refute response.fetch("result").key?("resultType")
          send_frame(input, request(3, "custom/echo", **modern_params(value: "wrong era")))
          assert_equal(-32600, read_frame(parent, output).dig("error", "code"))
        end
      end
      with_transport(parent) do |transport, input, output|
        send_frame(input, request(1, "server/discover"))
        assert_equal ["2026-07-28"], read_frame(parent, output).dig("result", "supportedVersions")
        send_frame(input, request(2, "custom/echo", **modern_params(value: "modern")))
        result = read_frame(parent, output).fetch("result")
        assert_equal "modern", result.fetch("value")
        assert_equal "complete", result.fetch("resultType")
        send_frame(input, request(3, "custom/echo", value: "missing envelope"))
        assert_equal(-32602, read_frame(parent, output).dig("error", "code"))
        send_frame(input, request(4, "initialize", protocolVersion: "2025-11-25", capabilities: {}, clientInfo: {name: "legacy", version: "1"}))
        assert_equal(-32601, read_frame(parent, output).dig("error", "code"))
        send_frame(input, request(5, "custom/echo", _meta: {"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}))
        assert_equal(-32602, read_frame(parent, output).dig("error", "code"))
      end
    end.wait
  end

  def test_reader_receives_cancellation_during_real_tmux_wait_and_eof_settles_owned_work
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |source|
        Async do |parent|
          scope = LibTmux::Async::Scope.new(parent: parent, server: source)
          entered, cancelled = [], []
          threads_before = Thread.list.length
          fds_before = Dir.children("/proc/self/fd").length if Dir.exist?("/proc/self/fd")
          sdk = sdk_server
          sdk.define_custom_method(method_name: "custom/wait") do |params, server_context:|
            entered << [Thread.current, server_context.cancellation]
            scope.server.run(["wait-for", "-S", "mcp-ready", ";", "wait-for", "mcp-held"], timeout: 0.5)
            {finished: true}
          rescue LibTmux::Cancelled => error
            cancelled << error
            raise
          end
          begin
            with_transport(parent, server: sdk) do |transport, input, output|
              send_frame(input, request(1, "server/discover"))
              read_frame(parent, output)
              send_frame(input, request(2, "custom/wait", **modern_params))
              scope.server.wait_for("mcp-ready", timeout: 0.5)
              send_frame(input, request(3, "custom/echo", **modern_params(value: "concurrent reader")))
              assert_equal "concurrent reader", read_frame(parent, output).dig("result", "value")
              refute entered.first.last.cancelled?
              send_frame(input, {jsonrpc: "2.0", method: "notifications/cancelled", params: {requestId: 2}})
              send_frame(input, request(4, "custom/echo", **modern_params(value: "reader progressed")))
              response = read_frame(parent, output)
              assert_equal 4, response.fetch("id")
              assert_equal "reader progressed", response.dig("result", "value")
              assert_equal Thread.current, entered.first.first
              assert entered.first.last.cancelled?
              send_frame(input, request(5, "custom/wait", **modern_params))
              scope.server.wait_for("mcp-ready", timeout: 0.5)
              input.close
            end
            assert source.run(["has-session", "-t", "fixture"]).success?
            assert_equal 2, cancelled.length
            cancelled.each { |error| assert_raises(Errno::ECHILD) { Process.waitpid(error.pid, Process::WNOHANG) } }
            assert_equal threads_before, Thread.list.length
            assert_equal fds_before, Dir.children("/proc/self/fd").length if fds_before
          ensure
            scope.close
          end
        end.wait
      end
    end
  end

  def test_first_success_locks_the_era_and_modern_context_is_request_local
    Async do |parent|
      sdk = sdk_server
      sdk.define_custom_method(method_name: "custom/held") { |_, server_context:| ::Async::Notification.new.wait }
      with_transport(parent, server: sdk) do |_, input, output|
        send_frame(input, request(1, "custom/held", **modern_params))
        send_frame(input, request(2, "initialize", protocolVersion: "2025-11-25", capabilities: {}, clientInfo: {name: "legacy", version: "1"}))
        send_frame(input, {jsonrpc: "2.0", method: "notifications/cancelled", params: {requestId: 1}})
        assert_equal "2025-11-25", read_frame(parent, output).dig("result", "protocolVersion")
      end

      ready, release = ::Async::Notification.new, ::Async::Notification.new
      sdk = sdk_server
      sdk.define_custom_method(method_name: "custom/context") do |params, server_context:|
        if params[:wait]
          ready.signal
          release.wait
        else
          release.signal
        end
        {client: server_context.client_info&.dig(:name), capabilities: server_context.client_capabilities}
      end
      with_transport(parent, server: sdk) do |_, input, output|
        send_frame(input, request(1, "server/discover"))
        read_frame(parent, output)
        first = modern_params(wait: true)
        first[:_meta]["io.modelcontextprotocol/clientInfo"] = {name: "first", version: "1"}
        first[:_meta]["io.modelcontextprotocol/clientCapabilities"] = {first: {}}
        send_frame(input, request(2, "custom/context", **first))
        parent.with_timeout(0.5) { ready.wait }
        send_frame(input, request(3, "custom/context", **modern_params))
        replies = 2.times.map { read_frame(parent, output) }.to_h { |entry| [entry.fetch("id"), entry.fetch("result")] }
        assert_equal "first", replies.fetch(2).fetch("client")
        assert_equal({"first" => {}}, replies.fetch(2).fetch("capabilities"))
        assert_nil replies.fetch(3).fetch("client")
        assert_equal({}, replies.fetch(3).fetch("capabilities"))
      end
    end.wait
  end

  def test_queued_cancellation_and_admission_limits_preserve_reader_progress
    Async do |parent|
      entered = 0
      sdk = sdk_server
      sdk.define_custom_method(method_name: "custom/held") do |params, server_context:|
        entered += 1
        ::Async::Notification.new.wait
        {}
      end
      with_transport(parent, server: sdk, concurrency: 1, max_requests: 2, max_request_bytes: 512) do |transport, input, output|
        send_frame(input, request(1, "server/discover"))
        read_frame(parent, output)
        send_frame(input, request(2, "custom/held", **modern_params))
        send_frame(input, request(3, "custom/held", **modern_params))
        send_frame(input, request(4, "custom/echo", **modern_params(value: "full")))
        refusal = read_frame(parent, output)
        assert_equal 4, refusal.fetch("id")
        assert_equal(-32000, refusal.dig("error", "code"))
        send_frame(input, {jsonrpc: "2.0", method: "notifications/cancelled", params: {requestId: 3}})
        send_frame(input, {jsonrpc: "2.0", method: "notifications/cancelled", params: {requestId: 2}})
        send_frame(input, request(5, "custom/echo", **modern_params(value: "x" * 600)))
        assert_equal(-32000, read_frame(parent, output).dig("error", "code"))
        send_frame(input, request(6, "custom/echo", **modern_params(value: "alive")))
        assert_equal "alive", read_frame(parent, output).dig("result", "value")
        assert_equal 1, entered
      end
    end.wait
  end

  def test_request_deadline_releases_dispatch_capacity
    Async do |parent|
      sdk = sdk_server
      sdk.define_custom_method(method_name: "custom/held") { |_| ::Async::Notification.new.wait }
      with_transport(parent, server: sdk, request_timeout: 0.02) do |_, input, output|
        send_frame(input, request(1, "custom/held"))
        assert_equal(-32000, read_frame(parent, output).dig("error", "code"))
        send_frame(input, request(2, "custom/echo", value: "after deadline"))
        assert_equal "after deadline", read_frame(parent, output).dig("result", "value")
      end
      elapsed = 0
      sdk.define_custom_method(method_name: "custom/clock") { |_| elapsed += 1; {expired: true} }
      with_transport(parent, server: sdk) do |transport, input, output|
        transport.define_singleton_method(:clock) { super() + elapsed }
        send_frame(input, request(1, "custom/clock"))
        assert_equal(-32000, read_frame(parent, output).dig("error", "code"))
      end
      with_transport(parent) do |transport, input, output|
        transport.define_singleton_method(:clock) { super() + elapsed }
        transport.define_singleton_method(:encode) do |message|
          super(message).tap { elapsed += 1 }
        end
        send_frame(input, request(1, "custom/echo", value: "encoding crossed deadline"))
        assert_equal(-32000, read_frame(parent, output).dig("error", "code"))
      end
    end.wait
  end

  def test_malformed_frames_use_sdk_errors_without_dispatching_batches
    Async do |parent|
      with_transport(parent) do |transport, input, output|
        input.write("{\n")
        assert_equal(-32700, read_frame(parent, output).dig("error", "code"))
        input.write("\xff\n".b)
        assert_equal(-32700, read_frame(parent, output).dig("error", "code"))
        send_frame(input, [request(1, "custom/echo", value: "batch")])
        assert_equal(-32600, read_frame(parent, output).dig("error", "code"))
        send_frame(input, request(2, "custom/echo", value: "survived"))
        assert_equal "survived", read_frame(parent, output).dig("result", "value")
      end
    end.wait
  end

  def test_input_and_output_byte_limits_and_slow_consumer_fail_with_bounded_cleanup
    Async do |parent|
      assert_raises(LibTmux::CapacityError) do
        with_transport(parent, max_frame_bytes: 64) { |_, input, _| input.write("x" * 65) }
      end
      sdk = sdk_server
      sdk.define_custom_method(method_name: "custom/large") { |_| {value: "é" * 200_000} }
      assert_raises(LibTmux::CapacityError) do
        with_transport(parent, server: sdk, max_output_bytes: 512) do |_, input, _|
          send_frame(input, request(1, "custom/large"))
          parent.yield
        end
      end
      assert_raises(LibTmux::DeadlineExceeded) do
        with_transport(parent, server: sdk, max_output_bytes: 1 << 20, write_timeout: 0.02) do |_, input, _, runner|
          send_frame(input, request(1, "custom/large"))
          error = runner.wait(timeout: 0.5)
          raise error if error.is_a?(Exception)
        end
      end
    end.wait
  end

  def test_readiness_waits_use_the_scheduler_without_helper_threads
    calls = []
    trace = TracePoint.new(:call, :c_call) do |event|
      calls << event.method_id if (event.self == IO && event.method_id == :select) ||
        (event.self == Thread && event.method_id == :new)
    end
    Async do |parent|
      trace.enable do
        with_transport(parent) do |_, input, output|
          send_frame(input, request(1, "custom/echo", value: "ready"))
          assert_equal "ready", read_frame(parent, output).dig("result", "value")
        end
      end
    end.wait
    assert_empty calls
  end

  def test_encoded_output_limit_is_checked_before_allocating_the_wire_frame
    Async do |parent|
      [{value: "\u0001" * 30}, Array.new(100, "")].each do |message|
        generated = []
        trace = TracePoint.new(:call, :c_call) { |event| generated << true if event.self == JSON && event.method_id == :generate }
        assert_raises(LibTmux::CapacityError) do
          with_transport(parent, max_output_bytes: 64) do |transport, _, _|
            trace.enable { transport.send_response(message) }
          end
        end
        assert_empty generated
      end
    end.wait
  end

  def test_repeated_cancellation_completes_retirement_before_restoring_sdk_transport
    Async do |parent|
      sdk = sdk_server
      previous = Object.new
      sdk.transport = previous
      entered, release = ::Async::Notification.new, ::Async::Notification.new
      retiring = false
      input, client_input = IO.pipe
      client_output, output = IO.pipe
      transport = LibTmux::MCP::StdioTransport.new(server: sdk, parent: parent, input: input, output: output)
      transport.define_singleton_method(:read_loop) do
        super()
      ensure
        retiring = true
        entered.signal
        release.wait
      end
      runner = parent.async do
        transport.run
      rescue Exception => error
        error
      end
      begin
        send_frame(client_input, request(1, "custom/echo", value: "started"))
        assert_equal "started", read_frame(parent, client_output).dig("result", "value")
        runner.cancel
        parent.with_timeout(0.5) { entered.wait until retiring }
        runner.cancel
        parent.yield
        assert_same transport, sdk.transport
        release.signal
        result = runner.wait(timeout: 0.5)
        assert_kind_of ::Async::Cancel, result
        assert transport.closed?
        assert_same previous, sdk.transport
      ensure
        release.signal
        parent.yield
        transport.instance_variable_get(:@reader)&.cancel
        transport.instance_variable_get(:@writer)&.cancel
        [input, output, client_input, client_output].each { |io| io.close unless io.closed? }
      end
    end.wait
  end

  def test_partial_task_startup_failure_retires_the_already_started_writer
    Async do |parent|
      sdk = sdk_server
      previous = Object.new
      sdk.transport = previous
      input, client_input = IO.pipe
      client_output, output = IO.pipe
      session_class = LibTmux::MCP::StdioTransport.const_get(:Session)
      trace = TracePoint.new(:call) do |event|
        raise NoMemoryError, "injected SDK session allocation failure" if event.method_id == :initialize && event.self.is_a?(session_class)
      end
      assert_raises(NoMemoryError) do
        trace.enable { LibTmux::MCP::StdioTransport.new(server: sdk, parent: parent, input: input, output: output) }
      end
      assert_same previous, sdk.transport
      transport = LibTmux::MCP::StdioTransport.new(server: sdk, parent: parent, input: input, output: output)
      count = 0
      transport.define_singleton_method(:child_task) do |&block|
        count += 1
        raise NoMemoryError, "injected task allocation failure" if count == 2
        super(&block)
      end
      begin
        assert_raises(NoMemoryError) { transport.run }
        assert transport.closed?
        assert transport.instance_variable_get(:@writer).finished?
        assert_same previous, sdk.transport
      ensure
        transport.instance_variable_get(:@writer)&.cancel
        [input, output, client_input, client_output].each { |io| io.close unless io.closed? }
      end

      failed = nil
      assert_raises(NoMemoryError) do
        with_transport(parent) do |candidate, client, _, runner|
          failed = candidate
          trace = TracePoint.new(:call) do |event|
            if event.method_id == :run && candidate.instance_variable_get(:@by_task).key?(event.self)
              raise NoMemoryError, "injected request fiber allocation failure"
            end
          end
          trace.enable do
            send_frame(client, request(1, "custom/echo", value: "never dispatched"))
            error = runner.wait(timeout: 0.5)
            raise error if error.is_a?(Exception)
          end
        end
      end
      assert failed.closed?
      assert_empty failed.instance_variable_get(:@tickets)
    end.wait
  end

  def test_failed_retirement_retains_ownership_until_close_can_retry
    Async do |parent|
      sdk = sdk_server
      previous = Object.new
      sdk.transport = previous
      ready, release = ::Async::Notification.new, ::Async::Notification.new
      handler = nil
      sdk.define_custom_method(method_name: "custom/cleanup") do |_|
        handler = ::Async::Task.current
        ready.signal
        begin
          ::Async::Notification.new.wait
        rescue ::Async::Cancel
          begin
            release.wait
          rescue ::Async::Cancel
            retry
          end
        end
        {}
      end
      primary = RuntimeError.new("injected primary failure")
      observed = assert_raises(RuntimeError) do
        with_transport(parent, server: sdk, cleanup_timeout: 0.02) do |transport, input, _, runner|
          send_frame(input, request(1, "custom/cleanup"))
          parent.with_timeout(0.5) { ready.wait until handler }
          input.close
          transport.instance_variable_set(:@failure, primary)
          error = runner.wait(timeout: 0.5)
          assert_same primary, error
          refute_empty error.mcp_cleanup_errors
          assert error.mcp_cleanup_errors.frozen?
          refute transport.closed?
          assert_same transport, sdk.transport
          release.signal
          handler.wait(timeout: 0.5)
          transport.close
          assert transport.closed?
          assert_same previous, sdk.transport
        ensure
          release.signal
          parent.yield
          handler&.cancel
        end
      end
      assert_same primary, observed
    end.wait
  end

  private

  def sdk_server
    sdk = ::MCP::Server.new(name: "transport-test", configuration: ::MCP::Configuration.new(exception_reporter: ->(*) {}))
    sdk.define_custom_method(method_name: "custom/echo") { |params, server_context:| {value: params[:value]} }
    sdk
  end

  def with_transport(parent, server: sdk_server, **limits)
    input, client_input = IO.pipe
    client_output, output = IO.pipe
    transport = LibTmux::MCP::StdioTransport.new(server: server, parent: parent, input: input, output: output,
      **{request_timeout: 0.5}.merge(limits))
    runner = parent.async do
      transport.run
    rescue Exception => error
      error
    end
    failure = nil
    begin
      yield transport, client_input, client_output, runner
    rescue Exception => error
      failure = error
    ensure
      client_input.close unless client_input.closed?
      begin
        result = runner.wait(timeout: 0.75)
        failure ||= result if result.is_a?(Exception)
      rescue Exception => error
        failure ||= error
      ensure
        [input, output, client_output].each { |io| io.close unless io.closed? }
      end
    end
    raise failure if failure
  end

  def request(id, method, **params)
    {jsonrpc: "2.0", id: id, method: method, params: params}
  end

  def modern_params(**params)
    params.merge(_meta: {"io.modelcontextprotocol/protocolVersion" => "2026-07-28", "io.modelcontextprotocol/clientCapabilities" => {}})
  end

  def send_frame(input, frame)
    input.write(JSON.generate(frame) + "\n")
  end

  def read_frame(parent, output)
    line = parent.with_timeout(0.5) { output.gets }
    JSON.parse(line)
  end
end
