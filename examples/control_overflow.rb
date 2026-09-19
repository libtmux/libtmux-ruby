# frozen_string_literal: true

require_relative "support"

Example.run("control_overflow") do |server|
  session = server.new_session(name: "control", command: ["/bin/cat"])
  window = session.list_windows.fetch(0)
  # docs:begin main
  server.open_control(session: session.ref) do |control|
    control.exchange("display-message -p ready", timeout: 0.5)
    reliable = control.subscribe(max_events: 1, max_bytes: 1024)
    tail = control.subscribe(mode: :tail, max_events: 1, max_bytes: 1024)
    3.times { |index| window.rename("event#{index}") }
    reply = control.exchange("display-message -p alive", timeout: 0.5)
    Example.check(reply.blocks.last.body == "alive\n", "slow reader blocked commands")
    Example.check(reply.attribution == :boundary_window, "reply overclaims attribution")
    reliable.next(timeout: 0.5)
    Example.raises(LibTmux::SubscriptionOverflow) { reliable.next(timeout: 0.5) }
    gap = tail.next(timeout: 0.5)
    Example.check(gap.kind == :gap && gap.dropped_bytes.positive?, "tail hid lost bytes")
  end
  # docs:end main
end
