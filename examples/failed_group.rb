# frozen_string_literal: true

require_relative "support"

Example.run("failed_group") do |server|
  server.new_session(name: "group", command: ["/bin/cat"])
  # docs:begin main
  group = server.run_group([
    ["set-option", "-g", "@before", "retained"],
    ["select-pane", "-t", "%4294967294"],
    ["set-option", "-g", "@after", "not-executed"]
  ])
  Example.check(!group.success?, "failing group succeeded")
  Example.check(group.steps.all? { |step| step.fetch(:outcome) == :unknown }, "invented per-step status")
  Example.check(server.options(scope: :session).get("@before").raw == "retained", "earlier effect rolled back")
  Example.check(server.options(scope: :session).list.none? { |option| option.name == "@after" }, "later step executed")
  # docs:end main
end
