# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"
  require "libtmux/async"

  LibTmux::Server.start do |server|
    Async do |parent|
      LibTmux::Async.open(parent: parent, server: server) do |scope|
        report = scope.server.capabilities
        puts "Control mode requires tmux #{report.feature('control-mode').since}"
      end
    end.wait
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
