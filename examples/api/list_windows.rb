# frozen_string_literal: true

require "libtmux"

begin
  LibTmux::Server.start do |server|
    work = server.new_session(name: "work", command: ["/bin/cat"])
    work.new_window(name: "logs", command: ["/bin/cat"])
    server.new_session(name: "other", command: ["/bin/cat"])
    puts "server windows: #{server.list_windows.length}"
    puts "work windows: #{work.list_windows.length}"
  end
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
