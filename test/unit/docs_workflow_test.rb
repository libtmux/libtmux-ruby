# frozen_string_literal: true

require "minitest/autorun"

class DocsWorkflowTest < Minitest::Test
  def test_preview_publication_uses_the_preview_role
    workflow = File.read(File.expand_path("../../.github/workflows/docs.yml", __dir__))

    assert_includes workflow,
      "role-arn: ${{ matrix.environment == 'docs-preview' && secrets.LIBTMUX_DOCS_PREVIEW_ROLE_ARN || secrets.LIBTMUX_DOCS_ROLE_ARN }}"
  end
end
