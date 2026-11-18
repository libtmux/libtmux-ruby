# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"

  LibTmux::Server.start do |server|
    report = server.capabilities
    feature = report.feature("layout-json")
    puts "JSON layouts require tmux #{feature.since}"
    puts "Refusal: #{feature.error}"
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
