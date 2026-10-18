# frozen_string_literal: true

begin
  # docs:begin main
  require "libtmux"

  LibTmux::Server.start do |server|
    server.new_session(name: "work", command: ["/bin/cat"])
    group = server.run_group([
      ["set-option", "-g", "@before", "kept"],
      ["select-pane", "-t", "%4294967294"],
      ["set-option", "-g", "@after", "never run"]
    ])
    puts "success: #{group.success?}"
    puts "steps: #{group.steps.map { |step| step.fetch(:outcome) }.join(', ')}"
    puts "@before: #{server.options(scope: :session).get('@before').as(:string)}"
  end
  # docs:end main
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  exit 1
end
