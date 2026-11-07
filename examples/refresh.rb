# frozen_string_literal: true

require_relative "support"
require "stringio"

Example.run("refresh") do |server|
  original_stdout = $stdout
  output = StringIO.new
  $stdout = output

  begin
    # docs:begin main
    session = server.new_session(name: "work", window_name: "editor", command: ["/bin/cat"])
    window = session.list_windows.fetch(0)

    held = window.snapshot
    window.rename("build")

    puts held.name
    puts window.snapshot.name
    # docs:end main
  ensure
    $stdout = original_stdout
  end

  Example.check(output.string == "editor\nbuild\n", "unexpected names")
end
