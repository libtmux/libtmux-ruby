# frozen_string_literal: true

require_relative "support"

Example.run("layout_io") do |server|
  # docs:begin main
  receipt = server.new_session(name: "layout", command: ["/bin/cat"], receipt: true)
  pane = receipt.pane
  second = pane.split(direction: :horizontal, size: "40%", command: ["/bin/cat"])
  receipt.window.select_layout("tiled")
  Example.check(receipt.window.list_panes.map(&:id).sort == [pane.id, second.id].sort, "assigned pane IDs differ")
  server.open_control(session: receipt.entity.ref) do |control|
    control.exchange("display-message -p ready", timeout: 0.5)
    output = control.subscribe(pane_id: pane.id, max_bytes: 8192, max_events: 32)
    literal = "literal; #{'#{pane_id}'} $HOME"
    pane.send_text(literal)
    bytes = "".b
    bytes << output.next(timeout: 0.5).data until bytes.include?(literal)
    Example.check(pane.capture.stdout.include?(literal), "capture lost literal input")
  end
  payload = "NUL\0\xff\n".b
  server.write_buffer(name: "bytes", data: payload)
  Example.check(server.read_buffer("bytes").stdout == payload, "buffer bytes changed")
  # docs:end main
end
