# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"
  require "libtmux/workspace"
  require "tmpdir"

  document = <<~'YAML'
    session_name: work
    environment:
      PROJECT_MODE: development
    windows:
      - window_name: editor
        window_index: 1
        layout: tiled
        panes:
          - shell_command: printf 'editor ready\n'
          - {}
  YAML

  Dir.mktmpdir("workspace-") do |directory|
    path = File.join(directory, "workspace.yaml")
    File.write(path, document)
    LibTmux::Server.start do |server|
      workspace = LibTmux::Workspace.load(path)
      plan = workspace.plan(snapshot: server.snapshot)
      puts "planned steps: #{plan.steps.length}"
      result = plan.apply(server: server)
      puts "applied: #{result.success?}"
      puts "sessions: #{server.list_sessions.map { |session| session.snapshot.name }.join(', ')}"
    end
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
