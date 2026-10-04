# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class DocsWorkflowTest < Minitest::Test
  def workflow
    YAML.load_file(File.expand_path("../../.github/workflows/docs.yml", __dir__))
  end

  def test_preview_publication_uses_the_preview_role
    workflow = File.read(File.expand_path("../../.github/workflows/docs.yml", __dir__))

    assert_includes workflow,
                    "role-arn: ${{ matrix.environment == 'docs-preview' && secrets.LIBTMUX_DOCS_PREVIEW_ROLE_ARN || secrets.LIBTMUX_DOCS_ROLE_ARN }}"
  end

  def test_source_exporter_and_docs_use_separate_checkouts
    build = workflow.fetch("jobs").fetch("build")
    steps = build.fetch("steps")
    checkouts = steps.select { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
    assert_equal %w[port docs-generator docs],
                 checkouts.map { |step| step.fetch("with").fetch("path") }
    assert_equal "${{ github.workspace }}/port",
                 build.fetch("env").fetch("LIBTMUX_DOCS_CHECKOUT_RUBY")
    assert_equal "${{ github.workspace }}/docs-generator",
                 build.fetch("env").fetch("LIBTMUX_DOCS_GENERATOR_CHECKOUT")
    snapshot =
      steps.index { |step| step.fetch("run", "").include?("publication-provenance.mjs snapshot") }
    exporter = steps.index { |step| step.fetch("name", "").start_with?("Export the selected") }
    assert snapshot && exporter && snapshot < exporter
    assert_equal "port", steps.fetch(exporter).fetch("working-directory")
    assert_includes steps.fetch(exporter).fetch("run"), '--source "$GITHUB_WORKSPACE/port"'
    tree = steps.find { |step| step.fetch("name", "").start_with?("Build the selected") }
    assert_equal "${{ runner.temp }}/build-inputs.json",
                 tree.fetch("env").fetch("LIBTMUX_DOCS_INPUT_SNAPSHOT")
    assert_equal "${{ steps.source.outputs.sha }}",
                 tree.fetch("env").fetch("LIBTMUX_DOCS_SOURCE_SHA")
  end

  def test_descriptor_uses_the_exact_content_upload
    jobs = workflow.fetch("jobs")
    steps = jobs.fetch("build").fetch("steps")
    content = steps.find { |step| step["id"] == "content" }.fetch("with")
    assert_equal true, content.fetch("include-hidden-files")
    descriptor =
      steps.find { |step| step.fetch("run", "").include?("publication-provenance.mjs descriptor") }
    assert_equal "${{ steps.content.outputs.artifact-id }}",
                 descriptor.fetch("env").fetch("ARTIFACT_ID")
    assert_equal "${{ steps.content.outputs.artifact-digest }}",
                 descriptor.fetch("env").fetch("ARTIFACT_DIGEST")
    assert_equal content.fetch("name"), descriptor.fetch("env").fetch("ARTIFACT_NAME")
    assert steps.any? { |step| step.dig("with", "name") == "#{content.fetch("name")}-publication" }
    docs = steps.find { |step| step.dig("with", "repository") == "libtmux/docs" }
    assert_match(/\A[0-9a-f]{40}\z/, docs.fetch("with").fetch("ref"))
    assert jobs.fetch("publish").fetch("uses").end_with?("@#{docs.fetch("with").fetch("ref")}")
  end

  def test_arbitrary_source_builds_do_not_restore_caches
    steps = workflow.fetch("jobs").fetch("build").fetch("steps")
    ruby = steps.find { |step| step.fetch("uses", "").start_with?("ruby/setup-ruby@") }
    assert_equal false, ruby.fetch("with").fetch("bundler-cache")
    node = steps.find { |step| step.fetch("uses", "").start_with?("actions/setup-node@") }
    refute node.fetch("with").key?("cache")
    bundle = steps.find { |step| step["run"] == "bundle install" }
    assert_equal "true", bundle.fetch("env").fetch("BUNDLE_FROZEN")
  end
end
