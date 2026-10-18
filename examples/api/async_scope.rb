# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"
  require "libtmux/async"

  LibTmux::Server.start do |server|
    server.new_session(name: "work", command: ["/bin/cat"])
    server.new_session(name: "logs", command: ["/bin/cat"])
    Async do |parent|
      LibTmux::Async.open(parent: parent, server: server) do |scope|
        refs = scope.server.list_panes.map(&:ref)
        screens = scope.map(refs, concurrency: 2) { |ref| scope.server.pane(ref).capture }
        puts "captured panes: #{screens.length}"
        puts "all succeeded: #{screens.all?(&:success?)}"
      end
    end.wait
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
