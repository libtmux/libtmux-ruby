# frozen_string_literal: true

require "libtmux"

begin
  LibTmux::Server.start do |server|
    created =
      server.new_session(
        name: "work",
        window_name: "main",
        command: ["/bin/cat"],
        receipt: true
      )
    puts "session: #{created.entity.id}"
    puts "window: #{created.window.id}"
    puts "pane: #{created.pane.id}"
  end
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
