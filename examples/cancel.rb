# frozen_string_literal: true

require "libtmux"
require_relative "support"

Example.run("cancel") do |server|
  server.new_session(name: "cancel", command: ["/bin/cat"])
  # docs:begin main
  cancellation = LibTmux::Cancellation.new
  waiting = nil
  begin
    waiting = Thread.new do
      server.run(["wait-for", "-S", "ready", ";", "wait-for", "held"],
        timeout: 0.5, cancel: cancellation)
    rescue LibTmux::Cancelled => error
      error
    end
    server.wait_for("ready", timeout: 0.5)
    cancellation.cancel
    failure = waiting.value
    Example.check(failure.is_a?(LibTmux::Cancelled), "cancellation lost")
    Example.check(failure.delivery == :possibly_sent, "dispatched wait claimed no effects")
    Example.raises(Errno::ECHILD) { Process.waitpid(failure.pid, Process::WNOHANG) }
    Example.check(server.diagnostics.fetch(:admitted_requests).zero?, "client remains admitted")
  ensure
    begin
      cancellation.cancel
      waiting&.join
    ensure
      cancellation.close
    end
  end
  # docs:end main
end
