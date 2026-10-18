# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"
  require "libtmux/workspace"

  LibTmux::Server.start do |server|
    workspace = LibTmux::Workspace.load(File.expand_path("../workspace.yaml", __dir__))
    plan = workspace.plan(snapshot: server.snapshot)
    puts "planned steps: #{plan.steps.length}"
    result = plan.apply(server: server)
    puts "applied: #{result.success?}"
    puts "sessions: #{server.list_sessions.map { |session| session.snapshot.name }.join(', ')}"
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
