# frozen_string_literal: true

require "open3"
require "libtmux"
require_relative "tmux_fixture"

module LibTmuxTest
  # Executes an unchanged consumer file against one foreground-owned daemon.
  class DefaultExampleHarness
    def self.run(example:, environment: ENV.to_h, ruby_options: [], injection: nil, timeout: 5.0)
      original = ENV.to_h
      executable = LibTmux::Endpoint.new(socket_path: "/unused", env: environment,
        executable: environment.fetch("LIBTMUX_TEST_TMUX", "tmux")).executable
      fixture = TmuxFixture.new(executable: executable)
      result = failure = nil
      begin
        fixture.start
        root = File.dirname(fixture.socket_path)
        bin = File.join(root, "bin")
        Dir.mkdir(bin, 0o700)
        File.symlink(executable, File.join(bin, "tmux"))
        options = ruby_options.dup
        if injection
          probe = File.join(root, "example-probe.rb")
          File.write(probe, injection)
          options.concat(["-r", probe])
        end
        child = environment.merge("PATH" => [bin, environment.fetch("PATH", "/usr/bin:/bin")].join(File::PATH_SEPARATOR),
          "LIBTMUX_SOCKET_PATH" => fixture.socket_path,
          "LIBTMUX_SOCKET_NAME" => "../ignored", "TMUX" => "/ignored,1,0", "TMUX_PANE" => "%99")
        worker = LibTmux::Internal::ProcessExecutor.new.run([Gem.ruby, *options, example],
          env: child, timeout: timeout)
        stdout, stderr, status = worker.stdout, worker.stderr, worker.status
        names, error, observed = fixture.tmux("list-sessions", "-F", '#{session_name}')
        raise "example observation failed: #{error}" unless observed.success?

        result = {stdout: stdout, stderr: stderr, status: status, sessions: names.lines.map(&:chomp),
          daemon_pid: fixture.daemon_pid, root: root, child_environment: child}
      rescue Exception => error
        failure = error
      ensure
        begin
          fixture.close
        rescue Exception => cleanup
          failure = failure ? LibTmux::CleanupError.new(body_error: failure, cleanup_error: cleanup) : cleanup
        end
      end
      raise failure if failure
      raise "example harness changed its host environment" unless original == ENV.to_h

      result.merge(daemon_status: fixture.daemon_status, retired_before_removal: fixture.retired_before_removal)
    end
  end
end
