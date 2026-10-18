# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"

  LibTmux::Server.start do |server|
    session = server.new_session(name: "work", command: ["/bin/cat"])
    window = session.list_windows.fetch(0)
    server.open_control(session: session.ref) do |control|
      reply = control.exchange("display-message -p ready", timeout: 5)
      puts "reply: #{reply.blocks.last.body.strip}"
      events = control.subscribe(max_events: 64, max_bytes: 65_536)
      window.rename("renamed")
      event = events.next(timeout: 5) until event&.raw&.start_with?("%window-renamed")
      puts "event: #{event.raw.strip}"
    end
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
