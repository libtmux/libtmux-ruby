# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"

  LibTmux::Server.start do |server|
    created = server.new_session(name: "work", command: ["/bin/sh"], receipt: true)
    pane = created.pane
    side = pane.split(direction: :horizontal, size: "40%", command: ["/bin/cat"])

    pane.send_text("echo ready")
    pane.send_keys("Enter")
    line = nil
    50.times do
      line = pane.capture.stdout.lines(chomp: true).find { |text| text == "ready" }
      break if line
      sleep 0.1
    end
    puts "captured: #{line}"

    created.window.resize(width: 100, height: 30)
    side.resize(width: 20)
    puts "side pane: #{side.snapshot.width} columns"
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
