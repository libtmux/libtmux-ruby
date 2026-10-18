# frozen_string_literal: true

module LibTmuxTest
  module ProcessCursorSupport
    def require_process_cursor_support(scope)
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
  end
end
