# frozen_string_literal: true

require_relative "support"
require "stringio"

original_stdout = $stdout
output = StringIO.new
$stdout = output

begin
  # docs:begin main
  require "libtmux"

  snapshot = LibTmux::Server.start do |server|
    session = server.new_session(name: "work", window_name: "main", command: ["/bin/cat"])
    window = session.new_window(name: "logs", command: ["/bin/cat"])
    window.split(direction: :horizontal, size: "40%", command: ["/bin/cat"])

    server.snapshot
  end

  snapshot.windows.each do |window|
    puts "#{window.name}: #{window.panes.map(&:id).join(', ')}"
  end
  # docs:end main

  # docs:begin queries
  panes = snapshot.panes
  active_ids = panes.where(active: true).map(&:id)
  wide_panes = panes.select { |pane| pane.width >= 40 }
  panes_by_window = panes.group_by { |pane| pane.window.name }

  logs = snapshot.windows.one(name: "logs")
  missing = snapshot.windows.one_or_nil(name: "missing")
  # docs:end queries

  Example.check(output.string == "main: %0\nlogs: %1, %2\n", "unexpected window listing")
  Example.check(panes.size == 3 && active_ids.size == 2, "unexpected pane selection")
  Example.check(wide_panes.map(&:id) == panes.where(width: {gte: 40}).map(&:id), "block selection differs")
  Example.check(panes_by_window.transform_values(&:size) == {"main" => 1, "logs" => 2}, "unexpected pane groups")
  Example.check(logs.panes.size == 2 && missing.nil?, "unexpected exact lookup")
ensure
  $stdout = original_stdout
end

puts(ENV["LIBTMUX_EXAMPLE_INSTALLED"] ? "PASS quickstart" : output.string)
