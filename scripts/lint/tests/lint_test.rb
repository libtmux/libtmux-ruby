# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../ruby_scripts"

class LintTest < Minitest::Test
  LINT = File.expand_path("../lint", __dir__)

  def lint(*arguments)
    Open3.capture2e(Gem.ruby, LINT, *arguments)
  end

  def test_discovery_finds_scripts_by_extension_and_by_shebang
    found = RubyScripts.find(File.expand_path("../../..", __dir__))

    assert_includes found, "scripts/lint/ruby_scripts.rb"
    assert_includes found, "scripts/lint/lint"
    refute_includes found, "scripts/lint/README.md"
  end

  def test_a_clean_file_passes
    Dir.mktmpdir do |dir|
      file = File.join(dir, "clean.rb")
      File.write(file, "# frozen_string_literal: true\n\nputs \"hello\"\n")

      output, status = lint(file)

      assert status.success?, output
    end
  end

  def test_a_violation_fails_and_names_the_rule
    Dir.mktmpdir do |dir|
      file = File.join(dir, "dirty.rb")
      File.write(file, "# frozen_string_literal: true\n\nputs 'single quoted'\n")

      output, status = lint(file)

      refute status.success?, output
      assert_includes output, "Style/StringLiterals"
    end
  end
end
