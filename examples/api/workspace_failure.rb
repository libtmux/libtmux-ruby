# frozen_string_literal: true

begin
  # docs:begin main
  require "json"
  require "libtmux"
  require "libtmux/workspace"

  LibTmux::Server.start do |server|
    server.new_session(name: "borrowed", command: ["/bin/cat"])
    crowded = LibTmux::Workspace.parse(
      JSON.generate({session_name: "crowded", windows: [{window_name: "small", panes: Array.new(40) { {} }}]}),
      format: :json, base_directory: __dir__
    )
    begin
      crowded.plan.apply(server: server, compensate: true)
    rescue LibTmux::Workspace::ApplyError => error
      puts "failed action: #{error.result.failed_action}"
      puts "created a session: #{error.result.created_refs.key?('session')}"
      puts "compensation: #{error.result.compensation}"
    end
    puts "sessions: #{server.list_sessions.map { |session| session.snapshot.name }.join(', ')}"
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
