# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"

VERSION_SCRIPT = File.expand_path("../../scripts/version", __dir__)
load VERSION_SCRIPT if File.file?(VERSION_SCRIPT)

class VersionTest < Minitest::Test
  VERSION_FILES = %w[
    gems/libtmux/lib/libtmux/version.rb
    gems/libtmux-async/lib/libtmux/async/version.rb
    gems/libtmux-mcp/lib/libtmux/mcp/version.rb
    gems/libtmux-workspace/lib/libtmux/workspace/version.rb
  ].freeze

  def test_bump_updates_owned_versions_and_preserves_external_lock_entries
    with_repository do |root|
      external = external_lock_content(File.read(File.join(root, "Gemfile.lock")))

      assert_equal "0.1.0.alpha.1", bump(root, "0.1.0.alpha.1")

      VERSION_FILES.each do |path|
        assert_includes File.read(File.join(root, path)), 'VERSION = "0.1.0.alpha.1"'
      end
      %w[libtmux-async libtmux-mcp libtmux-workspace].each do |name|
        gemspec = File.read(File.join(root, "gems", name, "#{name}.gemspec"))
        refute_includes gemspec, "0.1.0.pre"
        assert_includes gemspec, '"= #{spec.version}"'
      end
      lock = File.read(File.join(root, "Gemfile.lock"))
      refute_includes lock, "0.1.0.pre"
      assert_equal external, external_lock_content(lock)
      assert_includes lock, "libtmux-mcp (0.1.0.alpha.1)"
      assert_includes lock, "libtmux-async (= 0.1.0.alpha.1)"
      readme = File.read(File.join(root, "README.md"))
      assert_includes readme, "pkg/libtmux-0.1.0.alpha.1.gem"
    end
  end

  def test_invalid_or_backward_versions_do_not_edit_files_and_equal_is_safe
    with_repository(version: "0.1.0.alpha.2") do |root|
      before = contents(root)
      assert_raises(version_error) { bump(root, "1.0.0-rc1") }
      assert_equal before, contents(root)
      assert_raises(version_error) { bump(root, "0.1.0.alpha.1") }
      assert_equal before, contents(root)
      assert_equal "0.1.0.alpha.2", bump(root, "0.1.0.alpha.2")
      assert_equal before, contents(root)
    end
  end

  def test_successive_bumps_reload_gemspec_version_sources_in_the_same_process
    with_repository do |root|
      assert_equal "0.1.0.alpha.1", bump(root, "0.1.0.alpha.1")
      assert_equal "0.1.0.alpha.2", bump(root, "0.1.0.alpha.2")
      before = contents(root)
      assert_equal "0.1.0.alpha.2", bump(root, "0.1.0.alpha.2")
      assert_equal before, contents(root)
      assert_equal "0.1.0.alpha.3", bump(root, "0.1.0.alpha.3")
    end
  end

  def test_equivalent_version_with_different_spelling_fails_before_edits
    with_repository(version: "0.1.0.alpha.2") do |root|
      before = contents(root)

      error = assert_raises(version_error) { bump(root, "0.1.0.alpha.2.0") }

      assert_match(/same version.*different spelling/, error.message)
      assert_equal before, contents(root)
    end
  end

  def test_inconsistent_package_versions_or_constraints_fail_before_edits
    with_repository do |root|
      path = File.join(root, VERSION_FILES.last)
      File.write(path, File.read(path).sub("0.1.0.pre", "0.1.0.alpha.9"))
      before = contents(root)
      assert_raises(version_error) { bump(root, "0.1.0.alpha.1") }
      assert_equal before, contents(root)
    end

    with_repository do |root|
      path = File.join(root, "gems/libtmux-mcp/libtmux-mcp.gemspec")
      File.write(path, File.read(path).sub("= 0.1.0.pre", "= 0.1.0.alpha.9"))
      before = contents(root)
      assert_raises(version_error) { bump(root, "0.1.0.alpha.1") }
      assert_equal before, contents(root)
    end
  end

  def test_semantic_duplicate_sibling_constraint_fails_before_edits
    with_repository do |root|
      path = File.join(root, "gems/libtmux-mcp/libtmux-mcp.gemspec")
      source = File.read(path).sub("end\n", "  spec.add_dependency('libtmux', '= 9.0.0')\nend\n")
      File.write(path, source)
      before = contents(root)

      assert_raises(version_error) { bump(root, "0.1.0.alpha.1") }
      assert_equal before, contents(root)
    end
  end

  def test_sibling_dependency_must_be_runtime
    with_repository do |root|
      path = File.join(root, "gems/libtmux-async/libtmux-async.gemspec")
      source = File.read(path).sub(
        %(  spec.add_dependency "libtmux", "= 0.1.0.pre"\n),
        %(  if false\n    spec.add_dependency "libtmux", "= 0.1.0.pre"\n  end\n) +
          %(  spec.add_development_dependency("libtmux", "= 0.1.0.pre")\n)
      )
      File.write(path, source)
      before = contents(root)

      assert_raises(version_error) { bump(root, "0.1.0.alpha.1") }
      assert_equal before, contents(root)
    end
  end

  def test_lockfile_dependency_under_wrong_package_fails_before_edits
    with_repository do |root|
      path = File.join(root, "Gemfile.lock")
      source = File.read(path).sub("      libtmux-async (= 0.1.0.pre)\n", "")
      source = source.sub(
        "    libtmux-workspace (0.1.0.pre)\n",
        "    libtmux-workspace (0.1.0.pre)\n      libtmux-async (= 0.1.0.pre)\n"
      )
      File.write(path, source)
      before = contents(root)

      assert_raises(version_error) { bump(root, "0.1.0.alpha.1") }
      assert_equal before, contents(root)
    end
  end

  def test_lockfile_dependency_under_nonlocal_spec_in_same_source_fails_before_edits
    with_repository do |root|
      path = File.join(root, "Gemfile.lock")
      source = File.read(path).sub(
        "      libtmux-async (= 0.1.0.pre)\n",
        "    shadow (1.0)\n      libtmux-async (= 0.1.0.pre)\n"
      )
      File.write(path, source)
      before = contents(root)

      assert_raises(version_error) { bump(root, "0.1.0.alpha.1") }
      assert_equal before, contents(root)
    end
  end

  def test_dormant_sibling_declaration_cannot_hide_stale_proposed_dependency
    with_repository do |root|
      path = File.join(root, "gems/libtmux-async/libtmux-async.gemspec")
      source = File.read(path).sub(
        %(  spec.add_dependency "libtmux", "= 0.1.0.pre"\n),
        %(  if false\n    spec.add_dependency "libtmux", "= 0.1.0.pre"\n  end\n) +
          %(  spec.add_dependency("libtmux", "= 0.1.0.pre")\n)
      )
      File.write(path, source)
      before = contents(root)

      assert_raises(version_error) { bump(root, "0.1.0.alpha.1") }
      assert_equal before, contents(root)
    end
  end

  private

  def bump(root, version)
    assert defined?(VersionBump), "version bump maintainer tool is missing"
    VersionBump.new(root).bump(version)
  end

  def version_error
    assert defined?(VersionBump), "version bump maintainer tool is missing"
    VersionBump::Error
  end

  def with_repository(version: "0.1.0.pre")
    Dir.mktmpdir("libtmux-ruby-version-") do |root|
      fixture = File.basename(root).split(/[^A-Za-z0-9]/).map(&:capitalize).join
      constants = VERSION_FILES.to_h do |path|
        name = path.split("/")[1].split("-").map(&:capitalize).join
        [path, "#{fixture}#{name}"]
      end
      constants.each do |path, constant|
        write(root, path, "# frozen_string_literal: true\n\nmodule #{constant}\n  VERSION = \"#{version}\"\nend\n")
      end
      VERSION_FILES.each do |version_path|
        name = version_path.split("/")[1]
        write(root, "gems/#{name}/#{name}.gemspec",
          gemspec(name, sibling_dependencies(name), version, version_path, constants.fetch(version_path)))
      end
      write(root, "README.md", "Install pkg/libtmux-#{version}.gem from the build output.\n")
      write(root, "Gemfile.lock", lockfile(version))
      yield root
    end
  end

  def gemspec(name, siblings, version, version_path, constant)
    dependencies = siblings.map { |dependency| %(  spec.add_dependency "#{dependency}", "= #{version}"\n) }.join
    relative_version = version_path.delete_prefix("gems/#{name}/").delete_suffix(".rb")
    <<~GEMSPEC
      require_relative "#{relative_version}"

      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = #{constant}::VERSION
        spec.authors = ["Test"]
        spec.summary = "Version fixture"
      #{dependencies}end
    GEMSPEC
  end

  def sibling_dependencies(name)
    {"libtmux" => [], "libtmux-async" => %w[libtmux],
     "libtmux-mcp" => %w[libtmux libtmux-async], "libtmux-workspace" => %w[libtmux]}.fetch(name)
  end

  def lockfile(version)
    <<~LOCK
      PATH
        remote: gems/libtmux-async
        specs:
          libtmux-async (#{version})
            async (~> 2.46.0)
            libtmux (= #{version})

      PATH
        remote: gems/libtmux-mcp
        specs:
          libtmux-mcp (#{version})
            libtmux (= #{version})
            libtmux-async (= #{version})

      PATH
        remote: gems/libtmux-workspace
        specs:
          libtmux-workspace (#{version})
            libtmux (= #{version})

      PATH
        remote: gems/libtmux
        specs:
          libtmux (#{version})

      GEM
        remote: https://rubygems.org/
        specs:
          async (2.46.0)
          json (3.0.2)

      DEPENDENCIES
        libtmux!
        libtmux-async!
        libtmux-mcp!
        libtmux-workspace!

      CHECKSUMS
        async (2.46.0) sha256=external
        json (3.0.2) sha256=external
        libtmux (#{version})
        libtmux-async (#{version})
        libtmux-mcp (#{version})
        libtmux-workspace (#{version})
    LOCK
  end

  def write(root, path, content)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def contents(root)
    Dir.glob("{README.md,Gemfile.lock,gems/**/*}", base: root).select do |path|
      File.file?(File.join(root, path))
    end.to_h { |path| [path, File.binread(File.join(root, path))] }
  end

  def external_lock_content(lockfile)
    lockfile.lines.reject do |line|
      line.match?(/^ {2,6}libtmux(?:-(?:async|mcp|workspace))?(?:!| \()/)
    end.join
  end
end
