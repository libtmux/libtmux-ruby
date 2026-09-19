# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/installed_gems"
require "fileutils"
require "open3"
require "rubygems/package"
require "tmpdir"

class PackageTest < Minitest::Test
  include LibTmuxTest::InstalledGems
  ROOT = File.expand_path("../..", __dir__)
  IMPORTS = {
    "libtmux" => "libtmux",
    "libtmux-async" => "libtmux/async",
    "libtmux-mcp" => "libtmux/mcp",
    "libtmux-workspace" => "libtmux/workspace"
  }.freeze

  # Outer: builds and installs artifacts into isolated gem homes.
  def test_installed_imports_use_declared_dependencies_without_starting_resources
    specs = IMPORTS.to_h do |name, _|
      manifest = File.join(ROOT, "gems", name, "#{name}.gemspec")
      assert File.file?(manifest), "missing independently buildable #{name} gemspec"
      [name, Gem::Specification.load(manifest)]
    end

    Dir.mktmpdir("libtmux-ruby-packaging-") do |directory|
      artifacts = specs.to_h do |name, spec|
        assert_equal "MIT", spec.license
        assert_includes spec.files, "LICENSE"
        assert spec.files.any? { |file| file.start_with?("sig/") }, "missing signatures: #{name}"
        refute spec.files.any? { |file| file.start_with?("test/", "vendor/", "benchmark/") }
        artifact = File.join(directory, "#{spec.full_name}.gem")
        Dir.chdir(File.join(ROOT, "gems", name)) { Gem::Package.build(spec, false, true, artifact) }
        [name, artifact]
      end

      IMPORTS.each do |name, import|
        home = File.join(directory, name)
        FileUtils.mkdir_p(File.join(directory, "#{name}-canonical"))
        File.symlink("#{name}-canonical", home)
        FileUtils.mkdir_p(File.join(home, "specifications"))
        local, external = dependency_closure(specs.fetch(name), specs)
        external.each { |spec| copy_dependency(spec, home) }
        environment = {
          "GEM_HOME" => home, "GEM_PATH" => home, "RUBYLIB" => nil,
          "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
          "TMUX" => nil, "TMUX_PANE" => nil
        }
        local.each do |spec|
          command = [Gem.ruby, File.join(RbConfig::CONFIG.fetch("bindir"), "gem"),
                     "install", "--local", "--no-document", artifacts.fetch(spec.name)]
          output, status = Open3.capture2e(environment, *command, chdir: directory)
          assert status.success?, "#{name} installation failed: #{output}"
        end
        source = <<~'RUBY'
          before_threads = Thread.list
          before_scheduler = Fiber.scheduler
          trace = TracePoint.new(:call, :c_call) do |event|
            if [:spawn, :exec, :fork, :system, :`].include?(event.method_id)
              raise "import attempted process creation: #{event.method_id}"
            end
            if event.self == Thread && [:new, :start].include?(event.method_id)
              raise "import attempted thread creation"
            end
            if event.self == Fiber && event.method_id == :set_scheduler
              raise "import attempted scheduler activation"
            end
          end
          trace.enable { require ARGV.fetch(0) }
          raise "import started a thread" unless Thread.list == before_threads
          raise "import changed scheduler" unless Fiber.scheduler == before_scheduler
          raise "missing version" unless LibTmux::VERSION.is_a?(String)
          own_features = $LOADED_FEATURES.select { |path| path.include?("/libtmux") }
          installed_home = File.realpath(ENV.fetch("GEM_HOME")) + File::SEPARATOR
          raise "repository import" unless own_features.all? { |path| File.realpath(path).start_with?(installed_home) }
          if ["libtmux", "libtmux/workspace"].include?(ARGV.fetch(0))
            raise "optional dependency installed" unless Gem::Specification.find_all_by_name("async").empty? && Gem::Specification.find_all_by_name("mcp").empty?
          end
        RUBY
        output, status = Open3.capture2e(environment, Gem.ruby, "-e", source, import, chdir: directory)
        assert status.success?, "#{name} import failed: #{output}"
        assert_empty output, "#{name} import wrote output"
        run_installed_shell_helper(environment, directory) if name == "libtmux-mcp"
        run_installed_examples(name, environment, directory)
        run_installed_type_consumer(name, environment, directory)
      end
    end
  end

  private

  def run_installed_shell_helper(environment, directory)
    source = <<~'RUBY'
      require 'libtmux/mcp'
      require 'libtmux/mcp/enrollment'
      path = File.join(Dir.pwd, 'helper.sock')
      listener = UNIXServer.new(path)
      invitation = LibTmux::MCP.const_get(:EnrollmentRegistry)::Invitation.new(reference: nil, capture: nil, listener: listener, path: path)
      _integration, _path, token, ruby, helper, load_path = invitation.shell_arguments
      installed_home = File.realpath(ENV.fetch('GEM_HOME')) + File::SEPARATOR
      raise 'helper is outside installed gem' unless File.realpath(helper).start_with?(installed_home)
      poison = File.join(Dir.pwd, 'untrusted-ruby')
      Dir.mkdir(poison)
      Dir.mkdir(File.join(poison, 'libtmux'))
      %w[socket.rb digest.rb libtmux/process.rb poison.rb].each do |name|
        File.write(File.join(poison, name), "raise 'ambient Ruby dependency was loaded'\n")
      end
      script = "printf '%s\\n' \"$PWD\" \"$TMUX\" \"$TMUX_PANE\"; printf '\\000\\377' >&2; exit 9"
      digest = Digest::SHA256.hexdigest(script)
      run_id = 'a' * 32
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
      command = ['/usr/bin/env', 'TMUX=literal $value;#', 'TMUX_PANE=%23', "RUBYOPT=-r#{poison}/poison", "RUBYLIB=#{poison}",
        "GEM_HOME=#{poison}", "GEM_PATH=#{poison}", ruby, '--disable=rubyopt,gems', '-I', load_path, helper, [path].pack('m0'), token, deadline.to_s, run_id, digest, 'ready']
      worker = Thread.new { LibTmux::Internal::ProcessExecutor.new.run(command, timeout: 0.5) }
      begin
        raise 'installed helper did not connect' unless IO.select([listener], nil, nil, 0.5)
        peer = listener.accept
        read_line = lambda do
          line = +''.b
          until line.end_with?("\n")
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise 'installed helper response deadline' unless remaining.positive? && IO.select([peer], nil, nil, remaining)
            line << peer.readpartial(1)
          end
          line.chomp
        end
        raise 'helper identity frame' unless read_line.call == "READY #{run_id} #{token} #{digest} #{Process.pid}"
        peer.write("GRANT #{run_id} #{token} #{digest}\n")
        raise 'helper grant frame' unless read_line.call == "AUTHORIZED #{run_id} #{token} #{digest}"
        peer.write("SCRIPT #{run_id} #{token} #{digest} #{script.bytesize} 4096 4096\n#{script}")
        expected = "#{Dir.pwd}\nliteral $value;#\n%23\n".b
        raise 'helper native status' unless read_line.call == "RESULT #{run_id} #{token} #{digest} EXIT 9 #{expected.bytesize} 2"
        raise 'helper output bytes' unless peer.read(expected.bytesize + 2) == expected + "\x00\xff".b
      ensure
        peer&.close
        listener.close
        File.unlink(path)
        raise 'helper owner did not settle' unless worker.join(0.5)
      end
      raise 'helper failed' unless worker.value.success?
    RUBY
    output, status = Open3.capture2e(environment, Gem.ruby, '-W:no-experimental', '-e', source, chdir: directory)
    assert status.success?, "installed authored helper closure failed: #{output}"
    assert_empty output, 'installed authored helper wrote protocol data outside its socket'
  end

end
