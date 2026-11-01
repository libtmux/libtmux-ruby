# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"

# scripts/apt-get.sh bounds apt-get and rotates the mirror list on a hang, so
# it protects a job only while every apt call goes through it. A run script that
# calls apt-get or apt itself brings the hang back, so the workflows and the
# composite actions must fail on one. The rule reads the parsed run strings, so
# a comment or a key that mentions apt-get does not count.
class WorkflowAptTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FILES = ".github/{workflows/*.yml,actions/*/action.yml}"
  WRAPPER = "scripts/apt-get.sh"

  # A command word: at the start of a line or after an operator, a control
  # keyword, sudo, env or a variable assignment. A path such as
  # ./scripts/apt-get.sh and a name such as apt-cache are not one.
  RAW_APT = /(?:\A|[;&|(`{!]|\$\(|\b(?:then|do|else)\s)\s*(?:sudo\s+(?:-\S+\s+)*)?(?:env\s+)?(?:\w+=\S*\s+)*(apt-get|apt)(?=\s|\z)/

  def self.raw_calls(script)
    script.gsub(/\\\n\s*/, " ").lines.reject { |line| line.lstrip.start_with?("#") }.filter_map do |line|
      line[RAW_APT, 1]
    end
  end

  def self.steps_of(document)
    jobs = document["jobs"]
    return (document.dig("runs", "steps") || []).map { |step| ["the action", step] } unless jobs.is_a?(Hash)

    jobs.flat_map { |name, job| (job["steps"] || []).map { |step| ["job #{name}", step] } }
  end

  def self.problems(document, path)
    steps_of(document).each_with_index.flat_map do |(owner, step), index|
      raw_calls(step["run"].to_s).map do |command|
        label = step["name"] || step["id"] || "step #{index + 1}"
        "#{path}: #{owner}, step #{label}: calls #{command} directly; run it through #{WRAPPER}"
      end
    end
  end

  def self.tree_problems(root)
    Dir.glob(File.join(root, FILES)).sort.flat_map do |file|
      problems(YAML.safe_load_file(file, aliases: false), file.delete_prefix("#{root}/"))
    end
  end

  def workflow(run)
    {"jobs" => {"build" => {"steps" => [{"name" => "Install tmux", "run" => run}]}}}
  end

  def test_the_workflows_route_apt_through_the_wrapper
    refute_empty Dir.glob(File.join(ROOT, FILES)), "the glob finds no workflow, so the rule checks nothing"
    assert_equal [], self.class.tree_problems(ROOT)
  end

  def test_a_raw_call_is_reported_with_its_place_and_the_fix
    message = "w.yml: job build, step Install tmux: calls apt-get directly; run it through scripts/apt-get.sh"
    assert_equal [message], self.class.problems(workflow("sudo apt-get update\n"), "w.yml")
  end

  def test_the_wrapper_passes
    assert_equal [], self.class.problems(workflow("./scripts/apt-get.sh update\n./scripts/apt-get.sh install --yes tmux\n"), "w.yml")
  end

  def test_each_spelling_of_a_raw_call_is_reported
    [
      "apt-get update", "sudo apt-get install --yes tmux", "sudo -E apt-get update", "sudo apt install tmux",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install tmux", "sudo env DEBIAN_FRONTEND=noninteractive apt-get install tmux",
      "set -e\nsudo apt-get update && sudo apt-get install tmux", "if ! sudo apt-get update; then exit 1; fi",
      "echo start; sudo apt-get update", "sudo \\\n  apt-get update"
    ].each do |run|
      refute_empty self.class.problems(workflow(run), "w.yml"), run.inspect
    end
  end

  def test_a_comment_or_a_mention_is_not_a_call
    [
      "# sudo apt-get update\n./scripts/apt-get.sh update", "  # apt-get is bounded by the wrapper",
      "echo \"run sudo apt-get update by hand\"", "apt-cache policy tmux", "cat scripts/apt-get.sh"
    ].each do |run|
      assert_equal [], self.class.problems(workflow(run), "w.yml"), run.inspect
    end
  end

  def test_a_composite_action_is_checked_too
    action = {"runs" => {"using" => "composite", "steps" => [{"run" => "sudo apt-get update", "shell" => "bash"}]}}
    assert_equal ["a/action.yml: the action, step step 1: calls apt-get directly; run it through scripts/apt-get.sh"],
      self.class.problems(action, "a/action.yml")
  end
end
