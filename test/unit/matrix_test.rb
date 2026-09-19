# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"

class MatrixTest < Minitest::Test
  def test_plan_preserves_all_required_cells_and_cannot_claim_missing_cells_pass
    path = File.expand_path("../../scripts/matrix", __dir__)
    assert File.file?(path), "required compatibility matrix runner is missing"
    output, error, status = Open3.capture3(Gem.ruby, path, "--plan")
    assert status.success?, error
    report = JSON.parse(output)
    assert_equal 36, report.fetch("cells").length
    assert_equal 36, report.fetch("cells").map { |cell| cell.fetch("id") }.uniq.length
    assert_equal "PARTIAL", report.fetch("status")
    assert report.fetch("cells").all? { |cell| cell.fetch("status") == "UNVERIFIED" }
    assert_equal %w[3.2a 3.3a 3.4 3.5a 3.6 3.7c], report.fetch("cells").map { |cell| cell.fetch("tmux") }.uniq
    output, _, status = Open3.capture3(Gem.ruby, path, "--require-all")
    refute status.success?
    assert_equal "PARTIAL", JSON.parse(output).fetch("status")
  end
end
