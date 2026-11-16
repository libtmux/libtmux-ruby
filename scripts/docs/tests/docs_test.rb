# frozen_string_literal: true

require_relative "../../../test/test_helper"
require "tmpdir"

class DocumentationSiteTest < Minitest::Test
  def test_rendered_links_require_a_real_destination_and_fragment
    path = File.expand_path("../docs", __dir__)
    assert File.file?(path), "rendered documentation checker is missing"
    load path unless defined?(DocumentationSite)
    Dir.mktmpdir("libtmux-ruby-links-") do |directory|
      File.write(File.join(directory, "index.html"), '<a href="target.html#missing">target</a>')
      failure = assert_raises(DocumentationSite::Error) { DocumentationSite.validate(directory) }
      assert_match(/missing destination/, failure.message)
      File.write(File.join(directory, "target.html"), '<h1 id="present">Title</h1>')
      failure = assert_raises(DocumentationSite::Error) { DocumentationSite.validate(directory) }
      assert_match(/missing fragment/, failure.message)
      File.write(File.join(directory, "index.html"), '<a href="target.html#present">target</a>')
      assert_equal 2, DocumentationSite.validate(directory)
    end
  end
end
