# frozen_string_literal: true

require "libtmux"

begin
  LibTmux::Server.start do |server|
    created = server.new_session(
      name: "capture", command: ["/bin/sh"],
      environment: {"ENV" => "/dev/null"}, receipt: true
    )
    pane = created.pane
    pane.send_text("printf '\\nlibtmux capture ready\\n'")
    pane.send_keys("Enter")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    captured = pane.capture.stdout.lines(chomp: true)
    until captured.include?("libtmux capture ready")
      raise "Output did not arrive within five seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
      captured = pane.capture.stdout.lines(chomp: true)
    end
    raise "Expected output is absent from the pane" unless captured.include?("libtmux capture ready")
    puts "libtmux capture ready"
  end
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
