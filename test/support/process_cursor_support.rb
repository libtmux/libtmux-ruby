# frozen_string_literal: true

module LibTmuxTest
  module ProcessCursorSupport
    def require_process_cursor_support(app, scope, tool: "tmux_capture")
      unless process_cursor_tmux_supported?(scope)
        ref = scope.server.list_panes.first.ref
        arguments = {target: {generation: ref.binding_key, kind: "pane", id: ref.id}}
        arguments.merge!(tool == "tmux_capture" ? {track: true} : {condition: {type: "process_exit"}})
        response = app.call(tool, arguments).structured_content
        refute response.fetch("ok"), response.inspect
        assert_equal "unsupported", response.dig("error", "code"), response.inspect
        assert_equal "not_sent", response.dig("error", "delivery"), response.inspect
        return false
      end

      if /\A(?:arm64|x86_64)-darwin/.match?(RUBY_PLATFORM)
        snapshot = scope.server.snapshot
        failure = lease = nil
        begin
          lease = LibTmux::MCP.const_get(:ProcessIdentity).acquire(scope.server,
            server_pid: snapshot.server_info.fetch(:pid), pane_pid: snapshot.panes.first.pid,
            budget: scope.server.__send__(:operation_budget, 0.5, nil))
        rescue LibTmux::Error => error
          failure = error
        ensure
          lease&.close
        end
        assert_nil failure, "Darwin process identity is required: #{failure&.class}: #{failure&.message}"
        return true
      end
      failure = nil
      begin
        identity = LibTmux::MCP.const_get(:ProcessIdentity)
        namespace = identity.procfs_namespace
        sockets = Socket.pair(:UNIX, :STREAM)
        peer = IO.for_fd(sockets.first.getsockopt(Socket::SOL_SOCKET, 77).int)
      rescue LibTmux::UnsupportedFeatureError, SystemCallError => error
        failure = error
      ensure
        [namespace, peer, *sockets].compact.each { |io| io.close unless io.closed? }
      end
      assert_nil failure, "Linux process identity is required: #{failure&.class}: #{failure&.message}"
      true
    end

    def process_cursor_tmux_supported?(scope)
      version = scope.server.run(["display-message", "-p", '#{version}']).text.strip
      parts = /\A(\d+)\.(\d+)/.match(version)
      assert parts, "tmux did not report a parseable version"
      ([parts[1].to_i, parts[2].to_i] <=> [3, 3]) >= 0
    end
  end
end
