# frozen_string_literal: true

require "libtmux"

begin
  LibTmux::Server.start do |owner|
    owner.new_session(name: "work", command: ["/bin/cat"])
    server = LibTmux::Server.new(endpoint: owner.endpoint)
    begin
      puts "connected sessions: #{server.list_sessions.length}"
    ensure
      server.close
    end
    puts "sessions after client close: #{owner.list_sessions.length}"
  end
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
