# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"
  require "libtmux/async"

  LibTmux::Server.start do |server|
    server.new_session(name: "work", command: ["/bin/cat"])
    Async do |parent|
      LibTmux::Async.open(parent: parent, server: server) do |scope|
        waiting = parent.async do
          scope.server.run(["wait-for", "-S", "ready", ";", "wait-for", "held"], timeout: 5)
        rescue LibTmux::Cancelled => error
          error
        end
        scope.server.wait_for("ready", timeout: 5)
        waiting.cancel
        failure = waiting.wait
        puts "request: #{failure.class}"
        puts "delivery: #{failure.delivery}"
      end
    end.wait
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
