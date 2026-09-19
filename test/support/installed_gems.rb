# frozen_string_literal: true

require "fileutils"

module LibTmuxTest
  module InstalledGems
    private

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
