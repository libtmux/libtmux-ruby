# frozen_string_literal: true

require "libtmux"

begin
  LibTmux::Server.start do |server|
    work = server.new_session(name: "work", command: ["/bin/cat"], receipt: true)
    work.pane.split(direction: :horizontal, command: ["/bin/cat"])
    server.new_session(name: "other", command: ["/bin/cat"])
    puts "server panes: #{server.list_panes.length}"
    puts "work panes: #{work.entity.list_panes.length}"
    puts "window panes: #{work.window.list_panes.length}"
  end
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
