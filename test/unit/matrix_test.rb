# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"
require "tmpdir"

load File.expand_path("../../scripts/matrix", __dir__)

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

  def test_merge_rejects_pass_labels_without_executed_suite_evidence
    Dir.mktmpdir("libtmux-ruby-matrix-") do |directory|
      report = {"source_digest" => CompatibilityMatrix.digest,
        "cells" => CompatibilityMatrix.cells.map { |cell| cell.merge("status" => "PASS") }}
      File.write(File.join(directory, "matrix.json"), JSON.generate(report))
      result = nil
      output, = capture_io do
        result = CompatibilityMatrix.run(["--merge", directory, "--output", File.join(directory, "result")])
      end
      assert_equal 1, result
      combined = JSON.parse(output)
      assert_equal "PARTIAL", combined.fetch("status")
      assert combined.fetch("cells").all? { |cell| cell.fetch("status") == "INVALID_EVIDENCE" }

      report.fetch("cells").each do |cell|
        cell.merge!("exit_status" => 0, "observed_ruby" => cell.fetch("ruby"), "observed_tmux" => "tmux #{cell.fetch('tmux')}",
          "ruby_sha256" => "a" * 64, "tmux_sha256" => "b" * 64, "whole_monotonic_seconds" => 1.0,
          "suites" => Array.new(3) { {"tests" => 1, "assertions" => 1, "failures" => 0, "errors" => 0, "skips" => 0} })
      end
      File.delete(File.join(directory, "result/matrix.json"))
      File.write(File.join(directory, "matrix.json"), JSON.generate(report))
      output, = capture_io do
        result = CompatibilityMatrix.run(["--merge", directory, "--output", File.join(directory, "result")])
      end
      assert_equal 0, result
      assert_equal "PASS", JSON.parse(output).fetch("status")

      report.fetch("cells").first.fetch("suites").first["skips"] = 1
      File.delete(File.join(directory, "result/matrix.json"))
      File.write(File.join(directory, "matrix.json"), JSON.generate(report))
      output, = capture_io do
        result = CompatibilityMatrix.run(["--merge", directory, "--output", File.join(directory, "result")])
      end
      assert_equal 1, result
      assert_equal "INVALID_EVIDENCE", JSON.parse(output).fetch("cells").first.fetch("status")
    end
  end

  def test_failed_identity_probe_cannot_dispatch_the_suite
    Dir.mktmpdir("libtmux-ruby-matrix-") do |directory|
      ruby, tmux = %w[ruby tmux].map { |name| File.join(directory, name) }
      marker = File.join(directory, "dispatched")
      File.write(ruby, "#!/bin/sh\nif [ \"$1\" = --disable=gems ]; then printf 4.0.7; else touch '#{marker}'; exit 7; fi\n")
      File.write(tmux, "#!/bin/sh\nprintf 'tmux 3.7c\\n'\nexit 1\n")
      [ruby, tmux].each { |path| File.chmod(0o700, path) }
      os = RUBY_PLATFORM.include?("darwin") ? "macos" : "linux"
      cell = CompatibilityMatrix.cells.find { |item| item.fetch("id") == "#{os}/4.0.7/3.7c" }
      result = CompatibilityMatrix.execute(cell, {"4.0.7" => ruby}, {"3.7c" => tmux}, directory)
      assert_equal "WRONG_TOOLCHAIN", result.fetch("status")
      refute File.exist?(marker)
    end
  end
end
