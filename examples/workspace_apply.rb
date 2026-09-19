# frozen_string_literal: true

require "libtmux/workspace"
require "open3"
require_relative "support"

Example.run("workspace_apply") do |server|
  borrowed = server.new_session(name: "borrowed", command: ["/bin/cat"])
  # docs:begin main
  workspace = LibTmux::Workspace.load(File.join(__dir__, "workspace.yaml"))
  plan = workspace.plan(snapshot: server.snapshot)
  Example.check(server.list_sessions.size == 1, "planning changed tmux")
  result = plan.apply(server: server)
  Example.check(result.success?, "workspace apply failed")
  Example.check(result.effects.any? { |effect| effect.outcome == :dispatch_only }, "shell dispatch overclaims completion")
  crowded = LibTmux::Workspace.parse(JSON.generate({
    session_name: "crowded", windows: [{window_name: "small", panes: Array.new(40) { {} }}]
  }), format: :json, base_directory: __dir__)
  error = Example.raises(LibTmux::Workspace::ApplyError) do
    crowded.plan.apply(server: server, compensate: true)
  end
  Example.check(!error.result.created_refs.empty?, "failure lost partial creation ledger")
  Example.check(error.result.compensation == :completed, "owned compensation failed")
  Example.check(server.list_sessions.map(&:ref).include?(borrowed.ref), "borrowed session was removed")
  # docs:end main
  executable = Gem.bin_path("libtmux-workspace", "libtmux-workspace")
  %w[validate plan].each do |operation|
    output, status = Open3.capture2e(Gem.ruby, executable, operation, "--json", File.join(__dir__, "workspace.yaml"))
    Example.check(status.success? && JSON.parse(output).is_a?(Hash), "installed CLI #{operation} failed")
  end
  result.created_refs.fetch("session").then { |ref| server.session(ref).kill }
  server.open_control(session: borrowed.ref) do |control|
    control.exchange("display-message -p ready")
    selector = server.list_clients.find { |client| client.fetch(:pid) == control.pid }.fetch(:name)
    output, status = Open3.capture2e(Gem.ruby, executable, "load", "--json", "--socket", server.endpoint.socket_path,
      "--switch", selector, File.join(__dir__, "workspace.yaml"))
    applied = JSON.parse(output)
    Example.check(status.success? && applied.fetch("success"), "installed CLI load/switch failed")
    client = server.list_clients.find { |entry| entry.fetch(:pid) == control.pid }
    Example.check(client.fetch(:session_id) == applied.fetch("created_refs").fetch("session").fetch("id"),
      "installed CLI did not switch the explicit current client")
  end
end
