# frozen_string_literal: true

require "libtmux"

module Example
  def self.executable
    ENV.fetch("LIBTMUX_TEST_TMUX", "tmux")
  end

  def self.check(value, message)
    raise message unless value
  end

  def self.raises(type)
    begin
      yield
    rescue type => error
      return error
    end
    raise "expected #{type}"
  end

  # Control clients attach only to tmux 3.7 and newer.
  def self.control?(server)
    (server.__send__(:tmux_release) <=> LibTmux::Internal::TmuxVersion.parse("3.7")) >= 0
  end

  def self.refuses_control(server, session)
    error = raises(LibTmux::UnsupportedFeatureError) { server.open_control(session: session.ref) }
    check(error.delivery == :not_sent, "control refusal reported a dispatch")
    check(server.list_clients.empty?, "a control client attached")
  end

  def self.run(name)
    path = pid = nil
    LibTmux::Server.start(executable: executable) do |server|
      path = server.endpoint.socket_path
      pid = Integer(server.run(["display-message", "-p", '#{pid}']).text, 10)
      yield server
    end
    check(!File.exist?(File.dirname(path)), "owned directory survived close")
    raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    if ENV["LIBTMUX_EXAMPLE_INSTALLED"]
      own = $LOADED_FEATURES.select { |feature| feature.include?("/libtmux/") || feature.end_with?("/libtmux.rb") }
      installed_home = File.realpath(ENV.fetch("GEM_HOME")) + File::SEPARATOR
      check(own.all? { |feature| File.realpath(feature).start_with?(installed_home) }, "example loaded repository source")
    end
    puts "PASS #{name}"
  end
end
