# frozen_string_literal: true

require "libtmux"

begin
  LibTmux::Server.start do |server|
    session = server.new_session(name: "work", command: ["/bin/cat"])
    window = session.new_window(name: "logs", command: ["/bin/cat"])
    puts "window: #{window.snapshot.name}"
    puts "session windows: #{session.list_windows.length}"
  end
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
