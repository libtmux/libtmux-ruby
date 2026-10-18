# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"

  LibTmux::Server.start do |server|
    session = server.new_session(name: "links", command: ["/bin/cat"])
    window = session.list_windows.fetch(0)
    session.link_window(window.ref, index: 4)
    session.link_window(window.ref, index: 9)
    links = session.list_window_links
    puts "indexes: #{links.map(&:index).join(', ')}"
    puts "windows: #{links.map { |link| link.window.id }.uniq.join(', ')}"
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
