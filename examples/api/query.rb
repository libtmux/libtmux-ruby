# frozen_string_literal: true

require "libtmux"

begin
  LibTmux::Server.start do |server|
    work =
      server.new_session(name: "work", command: ["/bin/cat"], receipt: true)
    server.new_session(name: "logs", command: ["/bin/cat"])
    snapshot = server.snapshot
    session = snapshot.sessions.where(name: "work").one
    puts "matching session: #{session.name}"
    missing = snapshot.sessions.one_or_nil(name: "missing")
    puts "missing session: #{missing.nil?}"
    panes = server.search_panes(where: { id: work.pane.id })
    puts "matching pane: #{panes.one.id}"
  end
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
