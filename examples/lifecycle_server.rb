# frozen_string_literal: true

require "libtmux"

LibTmux::Server.start do |server|
  server.new_session(name: "ownership", command: ["/bin/cat"])
  server.adopt do |daemon|
    pane = daemon.list_panes.first
    pane.adopt { puts "server adopted: true" }
  end
end
