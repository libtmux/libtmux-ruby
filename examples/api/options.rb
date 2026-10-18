# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"

  LibTmux::Server.start do |server|
    session = server.new_session(name: "work", command: ["/bin/cat"])
    session.options.set("history-limit", 5000)
    limit = session.options.get("history-limit")
    puts "history-limit: #{limit.as(:integer)}"
    puts "inherited: #{limit.inherited?}"
    session.hooks.set("after-new-window", command: "display-message created")
    puts "hook: #{session.hooks.get('after-new-window').as(:string)}"
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
