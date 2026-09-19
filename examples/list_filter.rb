# frozen_string_literal: true

require_relative "support"

Example.run("list_filter") do |server|
  # docs:begin main
  session = server.new_session(name: "capture", command: ["/bin/cat"])
  session.new_window(name: "second", command: ["/bin/cat"])
  snapshot = server.snapshot
  panes = snapshot.panes
  first = panes.one(id: panes.first.id)
  session.new_window(name: "later", command: ["/bin/cat"])
  Example.check(panes.size == 2, "captured membership changed")
  Example.check(panes.where(id: first.id).one.ref == first.ref, "wrong exact match")
  Example.raises(LibTmux::MultipleMatchesError) { panes.one }
  Example.check(panes.one_or_nil(id: "%4294967294").nil?, "missing pane was invented")
  # docs:end main
  server.close
  Example.check(panes.where(id: first.id).one.equal?(first), "local filtering needs live I/O")
end
