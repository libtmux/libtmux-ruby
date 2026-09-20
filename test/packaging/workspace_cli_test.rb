# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/installed_gems"
require_relative "../support/tmux_fixture"
require "json"
require "open3"
require "rubygems/package"
require "tmpdir"

class InstalledWorkspaceCLITest < Minitest::Test
  include LibTmuxTest::InstalledGems
  ROOT = File.expand_path("../..", __dir__)

  # Outer: builds and installs the workspace dependency closure, then loads real tmux.
  def test_installed_executable_validates_plans_and_loads_without_repository_imports
    specs = %w[libtmux libtmux-workspace].to_h do |name|
      [name, Gem::Specification.load(File.join(ROOT, "gems", name, "#{name}.gemspec"))]
    end
    Dir.mktmpdir("libtmux-ruby-installed-workspace-") do |directory|
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(directory, "canonical-home"))
      File.symlink("canonical-home", home)
      FileUtils.mkdir_p(File.join(home, "specifications"))
      local, external = dependency_closure(specs.fetch("libtmux-workspace"), specs)
      external.each { |spec| copy_dependency(spec, home) }
      environment = {"GEM_HOME" => home, "GEM_PATH" => home, "RUBYLIB" => nil,
        "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
        "BUNDLE_LOCKFILE" => nil, "BUNDLER_SETUP" => nil,
        "TMUX" => nil, "TMUX_PANE" => nil}
      local.each do |spec|
        artifact = package_artifact(spec, directory, ROOT)
        output, status = Open3.capture2e(environment, Gem.ruby, File.join(RbConfig::CONFIG.fetch("bindir"), "gem"),
          "install", "--local", "--no-document", artifact, chdir: directory)
        assert status.success?, "artifact installation failed: #{output}"
      end
      executable = File.join(home, "bin", "libtmux-workspace")
      assert File.file?(executable)
      output, error, status = Open3.capture3(environment, Gem.ruby, executable, "--version", chdir: directory)
      assert status.success?, "installed version failed: #{error}"
      assert_equal "#{specs.fetch('libtmux-workspace').version}\n", output
      assert_empty error
      config = File.join(directory, ".tmuxp.json")
      File.write(config, JSON.generate({session_name: "installed", windows: [{window_name: "one", panes: [{}]}]}))
      %w[validate plan].each do |command|
        output, error, status = Open3.capture3(environment, Gem.ruby, executable, command, "--json", chdir: directory)
        assert status.success?, "installed #{command} failed: #{error}"
        assert_empty error
        value = JSON.parse(output)
        assert_equal(command == "validate" ? true : "offline_create", command == "validate" ? value.fetch("valid") : value.fetch("mode"))
      end
      LibTmuxTest::TmuxFixture.open do |fixture|
        output, error, status = Open3.capture3(environment, Gem.ruby, executable, "load", "--json", "--socket", fixture.socket_path, chdir: directory)
        assert status.success?, "installed load failed: #{output} #{error}"
        assert_empty error
        value = JSON.parse(output)
        assert_equal true, value.fetch("success")
        assert_equal 3, value.fetch("created_refs").length
        assert_equal ["fixture", "installed"], fixture.tmux("list-sessions", "-F", '#{session_name}').first.lines.map(&:chomp).sort
        assert_empty fixture.tmux("list-clients").first
      end
      source = <<~'RUBY'
        require "libtmux/workspace/cli"
        installed_home = File.realpath(ENV.fetch("GEM_HOME")) + File::SEPARATOR
        own = $LOADED_FEATURES.select { |path| path.include?("/libtmux") }
        abort "repository import" unless own.all? { |path| File.realpath(path).start_with?(installed_home) }
        abort "optional dependency" unless %w[async mcp].all? { |name| Gem::Specification.find_all_by_name(name).empty? }
      RUBY
      output, status = Open3.capture2e(environment, Gem.ruby, "-e", source, chdir: directory)
      assert status.success?, output
      assert_empty output
    end
  end
end
