# frozen_string_literal: true

require_relative "support"
require "stringio"

original_stdout = $stdout
output = StringIO.new
$stdout = output

begin
  # docs:begin main
  require "libtmux"

  LibTmux::Server.start do |server|
    session = server.new_session(name: "work", window_name: "editor", command: ["/bin/cat"])
    window = session.list_windows.fetch(0)

    held = window.snapshot
    window.rename("build")

    puts held.name
    puts window.snapshot.name
  end
  # docs:end main

  Example.check(output.string == "editor\nbuild\n", "unexpected names")
ensure
  $stdout = original_stdout
end

puts(ENV["LIBTMUX_EXAMPLE_INSTALLED"] ? "PASS refresh" : output.string)
