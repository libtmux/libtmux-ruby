# frozen_string_literal: true

require "libtmux"

begin
  LibTmux::Server.start do |server|
    quiet_shell = { "ENV" => "/dev/null" }
    created =
      server.new_session(
        name: "capture",
        command: ["/bin/sh"],
        environment: quiet_shell,
        receipt: true
      )
    pane = created.pane
    server.open_control(session: created.entity.ref) do |control|
      control.exchange("display-message -p ready", timeout: 1)
      output =
        control.subscribe(pane_id: pane.id, max_bytes: 8192, max_events: 32)
      pane.send_text("printf '\\nlibtmux capture ready\\n'")
      pane.send_keys("Enter")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      bytes = "".b
      until bytes.lines(chomp: true).include?("libtmux capture ready")
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        unless remaining.positive?
          raise "Output did not arrive within five seconds"
        end
        bytes << output.next(timeout: remaining).data
      end
      captured = pane.capture.stdout.lines(chomp: true)
      unless captured.include?("libtmux capture ready")
        raise "Expected output is absent from the pane"
      end
      puts "libtmux capture ready"
    end
  end
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
