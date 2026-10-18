# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"

  LibTmux::Server.start do |server|
    server.new_session(name: "work", command: ["/bin/cat"])
    cancellation = LibTmux::Cancellation.new
    waiting = Thread.new do
      server.run(["wait-for", "-S", "ready", ";", "wait-for", "held"], timeout: 5, cancel: cancellation)
    rescue LibTmux::Cancelled => error
      error
    end
    server.wait_for("ready", timeout: 5)
    cancellation.cancel
    failure = waiting.value
    puts "request: #{failure.class}"
    puts "delivery: #{failure.delivery}"
    cancellation.close
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
