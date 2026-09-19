# frozen_string_literal: true

require_relative "support"

Example.run("window_links") do |server|
  # docs:begin main
  session = server.new_session(name: "links", command: ["/bin/cat"])
  window = session.list_windows.fetch(0)
  session.link_window(window.ref, index: 4)
  session.link_window(window.ref, index: 9)
  links = session.list_window_links
  Example.check(links.map(&:index) == [0, 4, 9], "link indexes differ")
  Example.check(links.map { |link| link.window.ref }.uniq == [window.ref], "window identity split")
  Example.check(links.map(&:ref).uniq.length == 3, "link contexts collapsed")
  links.find { |link| link.index == 9 }.select
  Example.check(session.display('#{window_index}').text == "9\n", "wrong current link")
  # docs:end main
end
