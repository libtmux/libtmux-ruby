# frozen_string_literal: true

require "libtmux"
require "securerandom"

LibTmux::Server.open do |server|
  server.with_session(name: "ruby-example-#{SecureRandom.hex(4)}", command: ["/bin/cat"]) do |session|
    puts "session windows: #{session.list_windows.length}"
  end
end
