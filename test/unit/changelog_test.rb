# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"

# Every published gem keeps a CHANGELOG.md of its own, ships it, and links it
# from its README. The first test holds this repository to that; the others
# break a copy of it one way at a time, because a check that cannot fail is not
# checking anything.
class ChangelogTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GEMS = %w[libtmux libtmux-async libtmux-mcp libtmux-workspace].freeze

  # Returns one message per way the gems under +root+ fall short.
  def shortfalls(root)
    GEMS.flat_map do |name|
      directory = File.join(root, "gems", name)
      path = File.join(directory, "CHANGELOG.md")
      next ["#{name}: CHANGELOG.md is missing"] unless File.file?(path)

      lines = outside_fences(File.read(path))
      problems = []
      problems << "#{name}: does not open with its own name" unless lines.include?("Notable changes to `#{name}`.")
      problems << "#{name}: has no unreleased section" unless lines.any? { |line| line.match?(/\A## \S+ \(unreleased\)\z/) }
      problems << "#{name}: gemspec does not ship CHANGELOG.md" unless spec_files(File.join(directory, "#{name}.gemspec")).include?("CHANGELOG.md")
      problems << "#{name}: README does not link CHANGELOG.md" unless File.read(File.join(directory, "README.md")).include?("](CHANGELOG.md)")
      problems
    end
  end

  # Loading a gemspec from a copy defines its VERSION constant again, which is
  # a warning here and nothing else.
  def spec_files(path)
    verbose, $VERBOSE = $VERBOSE, nil
    Gem::Specification.load(path).files
  ensure
    $VERBOSE = verbose
  end

  def outside_fences(text)
    fenced = false
    text.lines(chomp: true).reject do |line|
      toggled = line.match?(/\A {0,3}(```|~~~)/)
      fenced = !fenced if toggled
      toggled || fenced
    end
  end

  def test_every_gem_keeps_a_changelog_it_ships_and_links
    assert_equal [], shortfalls(ROOT)
  end

  def test_a_gem_without_a_changelog_is_reported
    with_copy do |root|
      File.delete(File.join(root, "gems/libtmux-mcp/CHANGELOG.md"))
      assert_equal ["libtmux-mcp: CHANGELOG.md is missing"], shortfalls(root)
    end
  end

  def test_another_gems_changelog_is_reported
    with_copy do |root|
      FileUtils.cp(File.join(root, "gems/libtmux/CHANGELOG.md"), File.join(root, "gems/libtmux-mcp/CHANGELOG.md"))
      assert_equal ["libtmux-mcp: does not open with its own name"], shortfalls(root)
    end
  end

  def test_a_changelog_without_an_unreleased_section_is_reported
    with_copy do |root|
      path = File.join(root, "gems/libtmux-async/CHANGELOG.md")
      File.write(path, File.read(path).sub(/^## \S+ \(unreleased\)$/, "## 9.9.9 (2026-01-01)"))
      assert_equal ["libtmux-async: has no unreleased section"], shortfalls(root)
      File.write(path, "Notable changes to `libtmux-async`.\n\n```markdown\n## 0.1.2 (unreleased)\n```\n")
      assert_equal ["libtmux-async: has no unreleased section"], shortfalls(root)
    end
  end

  def test_a_gemspec_that_stops_shipping_the_changelog_is_reported
    with_copy do |root|
      path = File.join(root, "gems/libtmux-workspace/libtmux-workspace.gemspec")
      File.write(path, File.read(path).sub("LICENSE README.md CHANGELOG.md", "LICENSE README.md"))
      assert_equal ["libtmux-workspace: gemspec does not ship CHANGELOG.md"], shortfalls(root)
    end
  end

  def test_a_readme_that_does_not_link_its_changelog_is_reported
    with_copy do |root|
      path = File.join(root, "gems/libtmux/README.md")
      File.write(path, File.read(path).gsub("](CHANGELOG.md)", "](LICENSE)"))
      assert_equal ["libtmux: README does not link CHANGELOG.md"], shortfalls(root)
    end
  end

  private

  # A copy of the files the check reads, so a break never touches the checkout.
  def with_copy
    Dir.mktmpdir("libtmux-ruby-changelog-") do |root|
      GEMS.each do |name|
        FileUtils.mkdir_p(File.join(root, "gems", name))
        %W[CHANGELOG.md README.md #{name}.gemspec].each do |file|
          FileUtils.cp(File.join(ROOT, "gems", name, file), File.join(root, "gems", name, file))
        end
        FileUtils.cp_r(File.join(ROOT, "gems", name, "lib"), File.join(root, "gems", name, "lib")) if File.directory?(File.join(ROOT, "gems", name, "lib"))
      end
      yield root
    end
  end
end
