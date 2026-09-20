# frozen_string_literal: true

require "libtmux/async"
require_relative "support"

Example.run("async_cancel") do |server|
  server.new_session(name: "async", command: ["/bin/cat"])
  # docs:begin main
  Async do |parent|
    LibTmux::Async.open(parent: parent, server: server) do |scope|
      waiting = parent.async do
        scope.server.run(["wait-for", "-S", "ready", ";", "wait-for", "held"], timeout: 0.5)
      rescue LibTmux::Cancelled => error
        error
      end
      scope.server.wait_for("ready", timeout: 0.5)
      Example.check(scope.diagnostics.fetch(:active_process_slots) == 1, "waiting client lost its slot")
      captures = scope.map(scope.server.list_panes.map(&:ref), concurrency: 2) do |ref|
        scope.server.pane(ref).capture
      end
      Example.check(captures.all?(&:success?), "sibling captures stalled")
      waiting.cancel
      failure = waiting.wait
      Example.check(failure.is_a?(LibTmux::Cancelled), "cancellation lost")
      Example.check(failure.delivery == :possibly_sent, "cancelled dispatch claimed no effects")
      Example.raises(Errno::ECHILD) { Process.waitpid(failure.pid, Process::WNOHANG) }
      Example.check(scope.server.diagnostics.fetch(:admitted_requests).zero?, "cancelled client remains admitted")
    end
  end.wait
  # docs:end main
end
