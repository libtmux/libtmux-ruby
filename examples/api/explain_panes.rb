# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"

  LibTmux::Server.start do |server|
    server.new_session(name: "work", command: ["/bin/cat"])
    criteria = {active: true}
    plan = server.explain_panes(where: criteria)
    puts "tmux reads: #{plan.fetch(:capture)}"
    puts "tmux filters: #{plan.fetch(:pushed) || 'nothing'}"
    puts "Ruby filters: #{plan.fetch(:residual).fetch('where').keys.join(', ')}"
    puts "matching panes: #{server.search_panes(where: criteria).length}"
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
