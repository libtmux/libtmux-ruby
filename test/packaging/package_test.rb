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
        run_installed_examples(name, environment, directory)
        run_installed_type_consumer(name, environment, directory)
      end
    end
  end

end
