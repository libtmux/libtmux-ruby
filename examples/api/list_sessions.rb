# frozen_string_literal: true

require "libtmux"

begin
  LibTmux::Server.start do |server|
    server.new_session(name: "work", command: ["/bin/cat"])
    server.new_session(name: "logs", command: ["/bin/cat"])
    sessions = server.list_sessions
    puts "sessions: #{sessions.map(&:id).sort.join(', ')}"
  end
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
