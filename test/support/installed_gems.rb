# frozen_string_literal: true

require "fileutils"

module LibTmuxTest
  module InstalledGems
    private

    def package_artifact(spec, directory, root)
      if ENV["LIBTMUX_RELEASE_DIR"]
        require "json"
        release = File.expand_path(ENV.fetch("LIBTMUX_RELEASE_DIR"), root)
        raise "release artifacts must be in pkg/release" unless release == File.join(root, "pkg/release")

        unless @release_manifest
          load File.join(root, "scripts/release.rb") unless defined?(GemRelease)
          identity = JSON.parse(File.read(File.join(release, "release.json")))
          @release_manifest = GemRelease.new(root).verify(tag: identity.fetch("tag"), commit: identity.fetch("commit"))
        end
        artifact = @release_manifest.fetch("artifacts").find { |entry| entry.fetch("name") == spec.name }
        raise "release version differs from checkout" unless artifact.fetch("version") == spec.version.to_s

        return File.join(release, artifact.fetch("filename"))
      end

      artifact = File.join(directory, "#{spec.full_name}.gem")
      Dir.chdir(File.join(root, "gems", spec.name)) { Gem::Package.build(spec, false, true, artifact) }
      artifact
    end

    def run_installed_examples(package, environment, directory)
      require "json"
      root = File.expand_path("../..", __dir__)
      manifest = JSON.parse(File.read(File.join(root, "examples/manifest.json")))
      destination = File.join(directory, "examples")
      FileUtils.cp_r(File.join(root, "examples"), destination) unless File.directory?(destination)
      manifest.fetch("programs").select { |entry| entry.fetch("gem") == package }.each do |entry|
        output, status = Open3.capture2e(environment.merge("LIBTMUX_EXAMPLE_INSTALLED" => "1"),
          Gem.ruby, "-W:no-experimental", File.join(directory, entry.fetch("path")), chdir: directory)
        assert status.success?, "installed example #{entry.fetch('id')} failed: #{output}"
        assert_equal "PASS #{entry.fetch('id')}\n", output
      end
    end

    def run_installed_type_consumer(package, environment, directory)
      # Runtime imports and recipes run before checker-only dependencies enter
      # this gem home, so they cannot hide an undeclared runtime dependency.
      _local, dependencies = dependency_closure(Gem::Specification.find_by_name("rbs"), {})
      dependencies.each { |spec| copy_dependency(spec, environment.fetch("GEM_HOME")) }
      consumer = File.join(directory, "type_consumer.rb")
      FileUtils.cp(File.expand_path("../types/consumer.rb", __dir__), consumer) unless File.file?(consumer)
      output, status = Open3.capture2e(environment.merge("LIBTMUX_EXAMPLE_INSTALLED" => "1"),
        Gem.ruby, "-W:no-experimental", consumer, package, chdir: directory)
      assert status.success?, "installed signature consumer #{package} failed: #{output}"
      report = JSON.parse(output)
      assert_equal package, report.fetch("package")
      refute_empty report.fetch("exercised")
      assert_equal false, report.fetch("whole_program_static_check")
      puts "Signature consumer #{package}: #{report.fetch('exercised').join(', ')}"
    end

    def dependency_closure(root, local_specs)
      ordered = []
      visited = {}
      visit = lambda do |spec|
        return if visited[spec.name]

        visited[spec.name] = true
        spec.runtime_dependencies.each do |dependency|
          child = local_specs[dependency.name] || Gem::Specification.find_by_name(dependency.name, dependency.requirement)
          assert dependency.matches_spec?(child), "unsatisfied #{dependency} for #{spec.name}"
          visit.call(child)
        end
        ordered << spec
      end
      visit.call(root)
      ordered.partition { |spec| local_specs.key?(spec.name) }
    end

    def copy_dependency(spec, home)
      return if spec.default_gem?

      FileUtils.mkdir_p(File.join(home, "gems"))
      FileUtils.cp_r(spec.full_gem_path, File.join(home, "gems", spec.full_name))
      FileUtils.cp(spec.loaded_from, File.join(home, "specifications", "#{spec.full_name}.gemspec"))
      return unless File.directory?(spec.extension_dir)

      target = File.join(home, spec.extension_dir.delete_prefix("#{spec.base_dir}/"))
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp_r(spec.extension_dir, target)
    end
  end
end
