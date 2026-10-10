# frozen_string_literal: true

require "libtmux"
require "securerandom"

LibTmux::Server.open do |server|
  name = "ruby-lifecycle-#{SecureRandom.hex(4)}"
  server.owned_session(name: name, command: ["/bin/cat"]) do |session|
    reused = server.find_or_create_session(name: name, command: ["/bin/cat"])
    puts "session reused: #{!reused.created?}"
    window = session.find_or_create_window(name: "worker", command: ["/bin/cat"])
    window.use do |resource|
      pane = resource.find_or_create_pane(identity: "worker", direction: :horizontal, command: ["/bin/cat"])
      pane.use { puts "pane created: #{pane.created?}" }
    end
    session.new_window(name: "adopt", command: ["/bin/cat"]).adopt do |window|
      puts "adopted panes: #{window.list_panes.length}"
    end
  end
end
