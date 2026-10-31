# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"
require "tmpdir"

load File.expand_path("../../scripts/ci-plan", __dir__)

# Every rule of the plan has a check, and every check has a deliberate break:
# the rule is replaced with its absence and the check has to notice. A check
# that passes with its rule removed proves nothing about the rule.
class CIPlanTest < Minitest::Test
  MANIFEST = CIManifest.load
  SUPPORTED = CIManifest.supported(MANIFEST)
  RUBIES = CIManifest.rubies(MANIFEST)
  OLDEST = SUPPORTED.first
  NEWEST = SUPPORTED.last
  NEWEST_RUBY = RUBIES.last
  UNSUPPORTED = MANIFEST.fetch("unsupported")
  DEVELOPMENT = MANIFEST.fetch("development")
  GOOD_NEEDS = {
    "plan" => {"result" => "success", "outputs" => {"release_artifacts" => "true", "run_cells" => "true",
      "run_unsupported" => "false", "run_development" => "false"}},
    "release_artifacts" => {"result" => "success"}, "cell" => {"result" => "success"},
    "unsupported" => {"result" => "skipped"}, "development" => {"result" => "skipped"}
  }.freeze

  def plan(event, manifest: MANIFEST, **inputs)
    CIPlan.plan(manifest, event: event, **inputs)
  end

  def tmuxes(result, key = "cells")
    result.fetch(key).map { |leg| leg.fetch("tmux") }.uniq
  end

  def refused(pattern, event: "workflow_dispatch", **inputs)
    error = assert_raises(CIPlan::Error, "the plan was not refused: #{pattern}") { plan(event, **inputs) }
    assert_match pattern, error.message
  end

  def manifest_with(release)
    copy = Marshal.load(Marshal.dump(MANIFEST))
    copy["supported"] << {"tmux" => release, "sha256" => "a" * 64}
    copy
  end

  def check_push_runs_the_edges_only
    result = plan("push")
    assert_equal "edges", result.fetch("scope")
    assert_equal [OLDEST, NEWEST], tmuxes(result)
    assert_equal RUBIES, result.fetch("cells").map { |cell| cell.fetch("ruby") }.uniq
    assert_equal RUBIES.length * 2, result.fetch("cells").length
    assert_equal [[], []], result.values_at("unsupported", "development")
    assert_equal true, result.fetch("release_artifacts")
  end

  def check_pull_request_runs_the_edges_only
    result = plan("pull_request")
    assert_equal [OLDEST, NEWEST], tmuxes(result)
    assert_equal [[], []], result.values_at("unsupported", "development")
  end

  def check_dispatch_defaults_to_the_edges
    result = plan("workflow_dispatch")
    assert_equal "edges", result.fetch("scope")
    assert_equal [OLDEST, NEWEST], tmuxes(result)
    assert_equal false, result.fetch("release_artifacts")
  end

  def check_a_schedule_runs_the_full_scope
    assert_equal "full", plan("schedule").fetch("scope")
  end

  def check_full_runs_the_whole_table
    result = plan("workflow_dispatch", scope: "full")
    assert_equal SUPPORTED, tmuxes(result)
    assert_equal RUBIES.length * SUPPORTED.length, result.fetch("cells").length
    assert_equal UNSUPPORTED.map { |entry| [entry["tmux"], entry["check"]] }, result.fetch("unsupported").map { |leg| leg.values_at("tmux", "check") }
    assert_equal DEVELOPMENT.map { |entry| entry["commit"] }, result.fetch("development").map { |leg| leg.fetch("ref") }
    assert_equal [NEWEST_RUBY], (result.fetch("unsupported") + result.fetch("development")).map { |leg| leg.fetch("ruby") }.uniq
    assert_equal CIPlan::FIXED_JOBS + result.values_at("cells", "unsupported", "development").sum(&:length), result.fetch("expected_jobs")
  end

  def check_an_explicit_scope_beats_the_event
    result = plan("push", scope: "full")
    assert_equal "full", result.fetch("scope")
    assert_equal false, result.fetch("release_artifacts")
    assert_equal "custom", plan("pull_request", scope: "custom", tmux_ref: "master").fetch("scope")
  end

  def check_the_manifest_alone_decides_the_table
    manifest = manifest_with("4.0")
    assert_equal [OLDEST, "4.0"], tmuxes(plan("push", manifest: manifest))
    assert_equal "4.0", tmuxes(plan("push", manifest: manifest, scope: "full")).last
  end

  def check_a_single_release_is_one_edge
    manifest = Marshal.load(Marshal.dump(MANIFEST))
    manifest["supported"] = manifest["supported"].first(1)
    assert_equal [OLDEST], tmuxes(plan("push", manifest: manifest))
  end

  def check_a_scope_must_be_known
    refused(/scope must be one of/, scope: "everything")
  end

  def check_an_unknown_event_is_refused
    refused(/no scope is defined/, event: "release")
  end

  def check_a_ref_list_needs_the_custom_scope
    refused(/only used with scope custom/, scope: "edges", tmux_ref: "master")
    refused(/only used with scope custom/, tmux_ref: "master")
  end

  def check_a_custom_run_needs_refs
    refused(/needs tmux-ref/, scope: "custom")
    refused(/needs tmux-ref/, scope: "custom", tmux_ref: " , ")
  end

  def check_every_ref_is_validated
    ["3.6b;id", "-upload-pack=x", "a b", "$(id)", "a..b", "a1b2c3d", "topic/", "x.lock"].each do |ref|
      refused(/tmux ref/, scope: "custom", tmux_ref: "master,#{ref}")
    end
  end

  def check_too_many_jobs_are_refused
    refs = Array.new(CIPlan::MAX_CUSTOM_LEGS + 1) { |number| "topic-#{number}" }.join(",")
    refused(/at most/, scope: "custom", tmux_ref: refs)
    refused(/at most/, scope: "custom", tmux_ref: "#{OLDEST},#{NEWEST},#{SUPPORTED[1]},#{SUPPORTED[2]},#{SUPPORTED[3]}")
  end

  def check_custom_names_resolve_to_their_job
    sha = "a" * 40
    refused_release = UNSUPPORTED.first
    result = plan("workflow_dispatch", scope: "custom", ruby: NEWEST_RUBY,
      tmux_ref: "#{OLDEST}, #{refused_release['tmux']},#{DEVELOPMENT.first['tmux']},master,#{sha},#{OLDEST}")
    assert_equal ["linux/#{NEWEST_RUBY}/#{OLDEST}"], result.fetch("cells").map { |cell| cell.fetch("id") }
    assert_equal CIManifest.sha256(MANIFEST, OLDEST), result.fetch("cells").first.fetch("sha256")
    assert_equal [[refused_release["tmux"], refused_release["check"], refused_release["sha256"]]],
      result.fetch("unsupported").map { |leg| leg.values_at("tmux", "check", "sha256") }
    assert_equal [[DEVELOPMENT.first["tmux"], DEVELOPMENT.first["commit"], "^tmux next-"], ["master", "master", ""], [sha, sha, ""]],
      result.fetch("development").map { |leg| leg.values_at("tmux", "ref", "expect") }
  end

  def check_the_ruby_input_narrows_the_jobs
    result = plan("workflow_dispatch", ruby: "#{RUBIES.first},#{RUBIES.last}")
    assert_equal [RUBIES.first, RUBIES.last], result.fetch("cells").map { |cell| cell.fetch("ruby") }.uniq
    sources = plan("workflow_dispatch", scope: "custom", tmux_ref: "master", ruby: RUBIES.first).fetch("development")
    assert_equal [RUBIES.first], sources.map { |leg| leg.fetch("ruby") }
    assert_equal [NEWEST_RUBY], plan("workflow_dispatch", scope: "custom", tmux_ref: "master").fetch("development").map { |leg| leg.fetch("ruby") }
    assert_equal RUBIES, plan("workflow_dispatch", scope: "custom", tmux_ref: NEWEST).fetch("cells").map { |cell| cell.fetch("ruby") }
  end

  def check_an_unknown_ruby_is_refused
    refused(/ruby must name versions/, ruby: "1.8.7")
  end

  def check_the_runner_is_chosen_from_the_images
    assert_equal CIPlan::RUNNERS.first, plan("push").fetch("os")
    assert_equal "ubuntu-latest", plan("workflow_dispatch", os: "ubuntu-latest").fetch("os")
    refused(/os must be one of/, os: "macos-15")
  end

  def check_one_job_gets_the_debug_session
    %w[before-tests on-failure].each do |mode|
      %w[master 3.8 3.0a].each do |ref|
        result = plan("workflow_dispatch", scope: "custom", tmux_ref: ref, ruby: NEWEST_RUBY, tmate: mode)
        assert_equal [mode], result.values_at("cells", "unsupported", "development").flatten.map { |leg| leg.fetch("tmate") }
      end
    end
  end

  def check_no_debug_session_by_default
    [plan("push"), plan("workflow_dispatch", scope: "full"),
      plan("workflow_dispatch", scope: "custom", tmux_ref: "master", tmate: "off")].each do |result|
      assert_equal ["off"], result.values_at("cells", "unsupported", "development").flatten.map { |leg| leg.fetch("tmate") }.uniq
    end
  end

  def check_several_jobs_cannot_share_a_debug_session
    refused(/exactly one job/, tmate: "on-failure")
    refused(/exactly one job/, scope: "full", tmate: "before-tests")
    refused(/exactly one job/, scope: "custom", tmux_ref: "master,3.0a", tmate: "on-failure")
    refused(/exactly one job/, scope: "custom", tmux_ref: OLDEST, tmate: "on-failure")
  end

  def check_a_debug_session_needs_a_dispatch
    %w[push pull_request].each do |event|
      refused(/only available on a workflow_dispatch/, event: event, scope: "custom", tmux_ref: "master", tmate: "on-failure")
    end
  end

  def check_a_debug_mode_must_be_known
    refused(/tmate must be one of/, scope: "custom", tmux_ref: "master", tmate: "always")
  end

  def check_the_dry_run_follows_the_event
    assert_equal [true, true], %w[push pull_request].map { |event| CIPlan.release_artifacts?(event, "") }
    assert_equal [false, false, false], [CIPlan.release_artifacts?("workflow_dispatch", ""), CIPlan.release_artifacts?("push", "full"),
      CIPlan.release_artifacts?("workflow_dispatch", "edges")]
  end

  def check_the_job_count_adds_up
    [plan("push"), plan("workflow_dispatch", scope: "full"), plan("push", scope: "full"),
      plan("workflow_dispatch", scope: "custom", tmux_ref: "master,#{NEWEST},3.3")].each do |result|
      assert_equal CIPlan.job_names(result).length, result.fetch("expected_jobs")
    end
    assert_equal RUBIES.length * 2 + 3, plan("push").fetch("expected_jobs")
  end

  def check_the_matrix_is_never_empty
    error = assert_raises(CIPlan::Error) { CIPlan.require_legs({"cells" => [], "unsupported" => [], "development" => []}) }
    assert_match(/no job/, error.message)
  end

  def check_the_report_needs_the_plan_and_every_planned_job
    assert_equal [], CIPlan.check_needs(GOOD_NEEDS)
    %w[plan release_artifacts cell].each do |job|
      %w[failure cancelled skipped].each do |result|
        refute_empty CIPlan.check_needs(GOOD_NEEDS.merge(job => GOOD_NEEDS.fetch(job).merge("result" => result))), [job, result].inspect
      end
      refute_empty CIPlan.check_needs(GOOD_NEEDS.reject { |key, _| key == job }), job
    end
  end

  def check_a_job_the_plan_left_out_must_not_have_run
    %w[unsupported development].each do |job|
      %w[success failure cancelled].each do |result|
        refute_empty CIPlan.check_needs(GOOD_NEEDS.merge(job => {"result" => result})), [job, result].inspect
      end
    end
  end

  def check_a_planned_optional_job_must_succeed
    outputs = GOOD_NEEDS.fetch("plan").fetch("outputs").merge("run_unsupported" => "true")
    needs = GOOD_NEEDS.merge("plan" => GOOD_NEEDS.fetch("plan").merge("outputs" => outputs))
    refute_empty CIPlan.check_needs(needs)
    assert_equal [], CIPlan.check_needs(needs.merge("unsupported" => {"result" => "success"}))
  end

  CHECKS = instance_methods(false).grep(/\Acheck_/).sort.freeze

  # Checks that state a default or a boundary no single removal can reach.
  WITHOUT_A_BREAK = %i[check_no_debug_session_by_default check_a_single_release_is_one_edge].freeze

  # The report rule as written, for the breaks that keep most of it.
  NEEDS_RULE = CIPlan.method(:check_needs)

  BREAKS = [
    ["the edges rule takes every version", :edge_versions, ->(supported) { supported }, :check_push_runs_the_edges_only],
    ["the edges are written into the plan", :edge_versions, ->(_supported) { [OLDEST, NEWEST] }, :check_the_manifest_alone_decides_the_table],
    ["a pull request runs the full scope", :resolve_scope, ->(event, scope) { event == "pull_request" ? "full" : CIPlan::EVENT_SCOPES.fetch(event) { scope } }, :check_pull_request_runs_the_edges_only],
    ["a dispatch ignores the scope it was given", :resolve_scope, ->(_event, _scope) { "edges" }, :check_full_runs_the_whole_table],
    ["a given scope loses to the event", :resolve_scope, ->(event, _scope) { CIPlan::EVENT_SCOPES.fetch(event) { "edges" } }, :check_an_explicit_scope_beats_the_event],
    ["a dispatch does not default to the edges", :resolve_scope, ->(_event, scope) { scope.to_s.empty? ? "full" : scope }, :check_dispatch_defaults_to_the_edges],
    ["a schedule runs the edges", :resolve_scope, ->(event, scope) { scope.to_s.empty? ? "edges" : scope }, :check_a_schedule_runs_the_full_scope],
    ["an unknown scope is accepted", :resolve_scope, ->(_event, scope) { scope.to_s.empty? ? "edges" : scope }, :check_a_scope_must_be_known],
    ["an unknown event is accepted", :resolve_scope, ->(event, scope) { scope.to_s.empty? ? CIPlan::EVENT_SCOPES.fetch(event, "edges") : (CIPlan::SCOPES.include?(scope) ? scope : "edges") }, :check_an_unknown_event_is_refused],
    ["refs the scope ignores are accepted", :check_scope_inputs, ->(_scope, _refs) {}, :check_a_ref_list_needs_the_custom_scope],
    ["a custom run without refs is planned", :custom_refs, ->(refs) { CIPlan.split_list(refs).empty? ? ["master"] : CIPlan.split_list(refs) }, :check_a_custom_run_needs_refs],
    ["a ref is not validated", :check_ref, ->(ref) { ref }, :check_every_ref_is_validated],
    ["the job count is unlimited", :require_legs, ->(_legs) {}, :check_the_matrix_is_never_empty],
    ["the ruby input is ignored", :select_rubies, ->(_requested, _available) { [] }, :check_the_ruby_input_narrows_the_jobs],
    ["an unknown ruby is accepted", :select_rubies, ->(requested, _available) { CIPlan.split_list(requested) }, :check_an_unknown_ruby_is_refused],
    ["the os input is ignored", :choose_image, ->(_image) { CIPlan::RUNNERS.first }, :check_the_runner_is_chosen_from_the_images],
    ["an unknown os is accepted", :choose_image, ->(image) { image.to_s.empty? ? CIPlan::RUNNERS.first : image }, :check_the_runner_is_chosen_from_the_images],
    ["no job gets the debug session", :assign_tmate, ->(_event, _mode, _legs) {}, :check_one_job_gets_the_debug_session],
    ["every job gets the debug session", :assign_tmate, ->(_event, mode, legs) { legs.values.flatten.each { |leg| leg["tmate"] = mode } }, :check_several_jobs_cannot_share_a_debug_session],
    ["the debug session runs outside a dispatch", :assign_tmate, ->(_event, mode, legs) { legs.values.flatten.first["tmate"] = mode unless mode == "off" }, :check_a_debug_session_needs_a_dispatch],
    ["an unknown debug mode is accepted", :assign_tmate, ->(event, mode, legs) { legs.values.flatten.first["tmate"] = mode if event == "workflow_dispatch" && mode != "off" }, :check_a_debug_mode_must_be_known],
    ["the dry run follows every event", :release_artifacts?, ->(_event, _scope) { true }, :check_the_dry_run_follows_the_event],
    ["the dry run ignores a given scope", :release_artifacts?, ->(event, _scope) { %w[push pull_request].include?(event) }, :check_the_dry_run_follows_the_event],
    ["every custom ref is built from source", :custom_legs, ->(manifest, refs, _cell_rubies, source_rubies) { {"cells" => [], "unsupported" => [], "development" => refs.product(source_rubies).map { |ref, ruby| CIPlan.source_leg(manifest, ref, ruby) }} }, :check_custom_names_resolve_to_their_job],
    ["the job names omit the legs", :job_names, ->(_result) { ["plan"] }, :check_the_job_count_adds_up],
    ["the report ignores the plan", :check_needs, ->(needs) { NEEDS_RULE.call(needs.merge("plan" => {"result" => "success", "outputs" => needs.dig("plan", "outputs")})) }, :check_the_report_needs_the_plan_and_every_planned_job],
    ["the report accepts a skip for a planned job", :check_needs, ->(needs) { NEEDS_RULE.call(needs).reject { |problem| problem.include?("finished skipped, not success") } }, :check_the_report_needs_the_plan_and_every_planned_job],
    ["the report accepts a job the plan left out running", :check_needs, ->(needs) { NEEDS_RULE.call(needs).reject { |problem| problem.end_with?("not skipped") } }, :check_a_job_the_plan_left_out_must_not_have_run],
    ["the report ignores a planned optional job", :check_needs, ->(needs) { NEEDS_RULE.call(needs).reject { |problem| problem.start_with?("unsupported") } }, :check_a_planned_optional_job_must_succeed]
  ].freeze

  def test_every_check_passes
    CHECKS.each { |check| send(check) }
  end

  # Constants that are rules: the value, and the check that must notice.
  CONSTANT_BREAKS = {FIXED_JOBS: [0, :check_the_job_count_adds_up],
    MAX_CUSTOM_LEGS: [1000, :check_too_many_jobs_are_refused]}.freeze

  def test_every_check_has_a_deliberate_break
    broken = BREAKS.map(&:last) + CONSTANT_BREAKS.values.map(&:last)
    assert_equal WITHOUT_A_BREAK.sort, (CHECKS - broken).sort
    assert_empty broken - CHECKS
  end

  def test_a_check_fails_when_its_rule_is_removed
    BREAKS.each do |description, rule, replacement, check|
      original = CIPlan.method(rule)
      CIPlan.define_singleton_method(rule, &replacement)
      begin
        assert_raises(Minitest::Assertion, "#{description}: #{check} still passed") { send(check) }
      ensure
        CIPlan.define_singleton_method(rule, original)
      end
    end
  end

  def test_the_constants_of_the_plan_are_rules_too
    CONSTANT_BREAKS.each do |name, (replacement, check)|
      original = CIPlan.const_get(name)
      CIPlan.send(:remove_const, name)
      CIPlan.const_set(name, replacement)
      begin
        assert_raises(Minitest::Assertion, "#{name} is not checked") { send(check) }
      ensure
        CIPlan.send(:remove_const, name)
        CIPlan.const_set(name, original)
      end
    end
  end

  def test_the_outputs_are_single_line_json_and_flags
    result = plan("push")
    outputs = CIPlan.outputs(result)
    assert_equal %w[scope os release_artifacts cells run_cells ids unsupported run_unsupported development run_development expected_jobs], outputs.keys
    outputs.each_value { |value| refute_includes value, "\n" }
    assert_equal result.fetch("cells"), JSON.parse(outputs.fetch("cells")).fetch("include")
    assert_equal %w[true false false true], outputs.values_at("run_cells", "run_unsupported", "run_development", "release_artifacts")
    assert_equal result.fetch("cells").map { |cell| cell["id"] }.join(","), outputs.fetch("ids")
    assert_equal "9", outputs.fetch("expected_jobs")
  end

  def test_the_command_writes_outputs_and_exits_nonzero_on_a_refused_plan
    Dir.mktmpdir("libtmux-ruby-ci-plan-") do |directory|
      output = File.join(directory, "output")
      script = File.expand_path("../../scripts/ci-plan", __dir__)
      _, error, status = Open3.capture3(Gem.ruby, script, "plan", "--event", "push", "--tmux-ref", "master", "--github-output", output)
      refute status.success?
      assert_match(/only used with scope custom/, error)
      refute File.exist?(output)

      stdout, error, status = Open3.capture3(Gem.ruby, script, "plan", "--event", "push", "--github-output", output)
      assert status.success?, error
      assert_equal "edges", JSON.parse(stdout).fetch("scope")
      assert_includes File.read(output), "run_cells=true\n"
    end
  end

  def test_verify_reads_the_needs_context
    script = File.expand_path("../../scripts/ci-plan", __dir__)
    _, error, status = Open3.capture3({"NEEDS" => JSON.generate(GOOD_NEEDS)}, Gem.ruby, script, "verify")
    assert status.success?, error
    bad = GOOD_NEEDS.merge("cell" => {"result" => "failure"})
    _, error, status = Open3.capture3({"NEEDS" => JSON.generate(bad)}, Gem.ruby, script, "verify")
    refute status.success?
    assert_match(/cell finished failure/, error)
    _, _, status = Open3.capture3({"NEEDS" => "{}"}, Gem.ruby, script, "verify")
    refute status.success?
  end
end
