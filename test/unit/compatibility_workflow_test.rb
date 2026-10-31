# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"

load File.expand_path("../../scripts/ci-plan", __dir__)

# The workflow takes its jobs from the plan and lists no version, the release
# stays bound to a full run, and a matrix entry that builds a tmux release but
# runs no version-check test would pass its job, so the workflow must fail on
# one. Each rule has a mutation that has to be reported.
class CompatibilityWorkflowTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW = YAML.safe_load_file(File.join(ROOT, ".github/workflows/compatibility.yml"), aliases: false)
  RELEASE = YAML.safe_load_file(File.join(ROOT, ".github/workflows/release.yml"), aliases: false)
  MANIFEST = CIManifest.load

  MATRIX_OUTPUTS = {"cell" => "cells", "unsupported" => "unsupported", "development" => "development"}.freeze
  FLAGS = {"release_artifacts" => "release_artifacts", "cell" => "run_cells", "unsupported" => "run_unsupported",
           "development" => "run_development"}.freeze

  def self.copy(object)
    Marshal.load(Marshal.dump(object))
  end

  def self.triggers(workflow)
    workflow.fetch("on") { workflow.fetch(true) }
  end

  def self.strings(object, skip = %w[description])
    case object
    when Hash then object.flat_map { |key, value| skip.include?(key) ? [] : strings(value, skip) }
    when Array then object.flat_map { |value| strings(value, skip) }
    when String then [object]
    else []
    end
  end

  def self.needs(job)
    Array(job["needs"])
  end

  def self.steps_of(job)
    job.fetch("steps", [])
  end

  # The matrix fields a job reads that its plan output does not carry.
  def self.field_problems(workflow)
    result = CIPlan.plan(MANIFEST, event: "workflow_dispatch", scope: "full")
    MATRIX_OUTPUTS.flat_map do |job, output|
      emitted = result.fetch(output).flat_map(&:keys).uniq
      read = strings(workflow.fetch("jobs").fetch(job)).flat_map { |text| text.scan(/matrix\.(\w+)/).flatten }.uniq
      (read - emitted).map { |field| "#{job}: reads matrix.#{field}, which the plan does not emit" }
    end
  end

  def self.problems(workflow, release)
    found = field_problems(workflow)
    jobs = workflow.fetch("jobs")
    names = CIManifest.supported(MANIFEST) + CIManifest.unsupported(MANIFEST) + MANIFEST.fetch("development").map { |entry| entry.fetch("tmux") }
    strings(workflow).each do |text|
      names.each do |name|
        found << "the workflow names tmux #{name}, which only the manifest may" if text.match?(/(?<![\w.])#{Regexp.escape(name)}(?![\w.])/)
      end
    end
    unless (%w[plan report] + FLAGS.keys - jobs.keys).empty?
      return [*found, "the workflow needs a plan, the conditional jobs and the report"]
    end

    MATRIX_OUTPUTS.each do |job, output|
      found << "#{job}: the matrix must come from the plan" unless jobs.fetch(job).dig("strategy", "matrix") == "${{ fromJSON(needs.plan.outputs.#{output}) }}"
      found << "#{job}: must run on the image the plan chose" unless jobs.fetch(job).fetch("runs-on") == "${{ needs.plan.outputs.os }}"
    end
    FLAGS.each do |job, flag|
      found << "#{job}: must wait for the plan" unless needs(jobs.fetch(job)) == ["plan"]
      found << "#{job}: runs when the plan says so and no other way" unless jobs.fetch(job)["if"] == "needs.plan.outputs.#{flag} == 'true'"
    end
    jobs.each do |name, job|
      found << "#{name}: the matrix is listed in the workflow" if job.dig("strategy", "matrix").is_a?(Hash)
    end

    report = jobs.fetch("report")
    found << "report: keeps its name, All required cells" unless report["name"] == "All required cells"
    found << "report: must run when a job it waits for failed" unless report["if"].to_s.delete(" ") == "${{always()}}"
    found << "report: must wait for every other job" unless needs(report).sort == (jobs.keys - ["report"]).sort
    verify = steps_of(report).find { |step| step["run"].to_s.include?("scripts/ci-plan verify") }
    found << "report: must verify the needs context with the plan script" unless verify && verify.dig("env", "NEEDS") == "${{ toJSON(needs) }}"
    merge = steps_of(report).find { |step| step["run"].to_s.include?("scripts/matrix --merge") }
    found << "report: must require the planned cells" unless merge && merge["run"].include?("--require-all") && merge["run"].include?('--only "$CELLS"') &&
      merge.dig("env", "CELLS") == "${{ needs.plan.outputs.ids }}"

    group = workflow.fetch("concurrency")
    # A dispatch and a call carry a scope, and a push and a pull request do not.
    found << "a dispatched or called run must have its own concurrency group" unless
      group["group"].include?("inputs.scope && github.run_id ||")
    found << "a push and a pull request must keep their groups" unless
      group["group"].include?("github.event_name == 'pull_request' && github.ref || github.sha")
    found << "only a pull request may cancel the run it supersedes" unless
      group["cancel-in-progress"] == "${{ github.event_name == 'pull_request' }}"

    inputs = triggers(workflow).dig("workflow_dispatch", "inputs")
    found << "the dispatch inputs are not the plan's" unless inputs.keys.sort == %w[os ruby scope tmate tmux-ref]
    found << "the scope input must offer exactly the plan's scopes and default to edges" unless
      inputs.dig("scope", "options") == CIPlan::SCOPES && inputs.dig("scope", "default") == "edges"
    found << "the os input must offer exactly the plan's runner images" unless inputs.dig("os", "options") == CIPlan::RUNNERS
    found << "the workflow_call scope input must be required" unless triggers(workflow).dig("workflow_call", "inputs", "scope", "required") == true
    plan_env = steps_of(jobs.fetch("plan")).filter_map { |step| step["env"] }.reduce({}, :merge)
    inputs.each_key do |name|
      found << "plan: the #{name} input must reach the plan" unless plan_env.values.include?("${{ inputs.#{name} }}")
    end
    jobs.each do |name, job|
      steps_of(job).each do |step|
        found << "#{name}: an input may reach a script only through env" if step["run"].to_s.include?("inputs.")
      end
    end
    found << "the workflow must not run on macOS" if strings(workflow).any? { |text| text.match?(/macos/i) }

    call = release.fetch("jobs").values.find { |job| job["uses"].to_s.end_with?("/compatibility.yml") }
    found << "release: a job must call compatibility.yml" unless call
    found << "release: the call must ask for scope full" unless call && call.dig("with", "scope") == "full"
    name = release.fetch("jobs").key(call)
    chain = release.fetch("jobs").transform_values { |job| needs(job) }
    reaches = ->(job) { chain.fetch(job).include?(name) || chain.fetch(job).any? { |parent| chain.key?(parent) && reaches.call(parent) } }
    (release.fetch("jobs").keys - [name]).each do |job|
      found << "release: #{job} must wait for the full compatibility run" unless reaches.call(job)
    end
    found
  end

  TMATE = "mxschmitt/action-tmate"
  TEST_JOBS = %w[cell unsupported development].freeze

  # What makes a debugging session unsafe or misplaced.
  def self.session_problems(workflow, release)
    found = []
    jobs = workflow.fetch("jobs")
    jobs.each do |name, job|
      sessions = steps_of(job).select { |step| step["uses"].to_s.start_with?(TMATE) }
      found << "#{name}: a debugging session belongs only in the test jobs" if !sessions.empty? && !TEST_JOBS.include?(name)
      next unless TEST_JOBS.include?(name)

      found << "#{name}: must offer a session before the tests and one after a failure" unless sessions.length == 2
      sessions.each do |step|
        found << "a debugging session must be pinned to a full commit SHA" unless step["uses"].match?(/\A#{TMATE}@[0-9a-f]{40}\z/)
        found << "a debugging session must be limited to the actor" unless step.dig("with", "limit-access-to-actor") == true
        found << "a debugging session needs its own time limit" unless step["timeout-minutes"].is_a?(Integer)
        found << "a debugging session runs only on a dispatch, on the job the plan chose" unless
          step["if"].to_s.include?("github.event_name == 'workflow_dispatch'") && step["if"].to_s.include?("matrix.tmate ==")
      end
      found << "#{name}: the job must cap its time and give the debugging job more" unless job["timeout-minutes"].to_s.match?(/\A\$\{\{ matrix\.tmate == 'off' && \d+ \|\| \d+ \}\}\z/)
    end
    inputs = triggers(workflow).dig("workflow_dispatch", "inputs")
    found << "the tmate input must offer exactly the plan's modes and default to off" unless
      inputs.dig("tmate", "options") == CIPlan::TMATE_MODES && inputs.dig("tmate", "default") == "off"
    plan_env = steps_of(jobs.fetch("plan")).filter_map { |step| step["env"] }.reduce({}, :merge)
    found << "plan: must pass the tmate input through env" unless plan_env["TMATE"] == "${{ inputs.tmate }}"
    found << "release: a release never opens a debugging session" if strings(release).any? { |text| text.include?(TMATE) }
    found
  end

  def reported(workflow, release, message)
    problems = self.class.problems(workflow, release)
    assert problems.any? { |problem| problem.include?(message) }, [message, problems].inspect
  end

  def mutate(&block)
    workflow = self.class.copy(WORKFLOW)
    release = self.class.copy(RELEASE)
    block.call(workflow, release)
    [workflow, release]
  end

  def test_the_workflows_follow_the_plan
    assert_equal [], self.class.problems(WORKFLOW, RELEASE)
  end

  MUTATIONS = {
    "a tmux version returns to the workflow" => [->(w, _r) { w["jobs"]["cell"]["env"]["PINNED"] = "3.6" }, "names tmux 3.6"],
    "the development commit returns to the workflow" => [->(w, _r) { w["jobs"]["development"]["env"]["REF"] = "next-3.9" }, "names tmux next-3.9"],
    "a job reads a field the plan does not emit" => [->(w, _r) { w["jobs"]["cell"]["env"]["RUNNER"] = "${{ matrix.platform.runner }}" }, "cell: reads matrix.platform"],
    "a matrix is listed again" => [->(w, _r) { w["jobs"]["cell"]["strategy"]["matrix"] = {"ruby" => ["4.0.7"]} }, "the matrix must come from the plan"],
    "a matrix reads another output" => [->(w, _r) { w["jobs"]["unsupported"]["strategy"]["matrix"] = "${{ fromJSON(needs.plan.outputs.cells) }}" }, "unsupported: the matrix must come from the plan"],
    "a job runs on a fixed image" => [->(w, _r) { w["jobs"]["cell"]["runs-on"] = "ubuntu-24.04" }, "must run on the image the plan chose"],
    "a job stops waiting for the plan" => [->(w, _r) { w["jobs"]["development"].delete("needs") }, "development: must wait for the plan"],
    "a job runs on an event instead of the plan" => [->(w, _r) { w["jobs"]["release_artifacts"]["if"] = "github.event_name != 'workflow_dispatch'" }, "release_artifacts: runs when the plan says so"],
    "a job runs when another flag says so" => [->(w, _r) { w["jobs"]["unsupported"]["if"] = "needs.plan.outputs.run_cells == 'true'" }, "unsupported: runs when the plan says so"],
    "the report is renamed" => [->(w, _r) { w["jobs"]["report"]["name"] = "Report" }, "keeps its name"],
    "the report is skipped after a failure" => [->(w, _r) { w["jobs"]["report"].delete("if") }, "must run when a job it waits for failed"],
    "the report forgets a job" => [->(w, _r) { w["jobs"]["report"]["needs"] -= ["development"] }, "must wait for every other job"],
    "a job is added that the report does not wait for" => [->(w, _r) { w["jobs"]["extra"] = {"runs-on" => "ubuntu-24.04", "steps" => []} }, "must wait for every other job"],
    "the report stops verifying the plan" => [->(w, _r) { w["jobs"]["report"]["steps"].reject! { |s| s["run"].to_s.include?("ci-plan verify") } }, "must verify the needs context"],
    "the report requires every cell again" => [->(w, _r) { w["jobs"]["report"]["steps"].find { |s| s["run"].to_s.include?("matrix --merge") }["run"].sub!(' --only "$CELLS"', "") }, "must require the planned cells"],
    "a dispatch shares its group with the push" => [->(w, _r) { w["concurrency"]["group"] = w["concurrency"]["group"].sub("inputs.scope && github.run_id || ", "") }, "must have its own concurrency group"],
    "a pull request shares one group with every other" => [->(w, _r) { w["concurrency"]["group"] = w["concurrency"]["group"].sub("github.event_name == 'pull_request' && github.ref || ", "") }, "must keep their groups"],
    "every run cancels its predecessor" => [->(w, _r) { w["concurrency"]["cancel-in-progress"] = true }, "only a pull request may cancel"],
    "an input is dropped from the dispatch" => [->(w, _r) { CompatibilityWorkflowTest.triggers(w)["workflow_dispatch"]["inputs"].delete("ruby") }, "the dispatch inputs are not the plan's"],
    "the scope input defaults to full" => [->(w, _r) { CompatibilityWorkflowTest.triggers(w)["workflow_dispatch"]["inputs"]["scope"]["default"] = "full" }, "default to edges"],
    "the scope input offers another scope" => [->(w, _r) { CompatibilityWorkflowTest.triggers(w)["workflow_dispatch"]["inputs"]["scope"]["options"] = %w[edges full] }, "the plan's scopes"],
    "the os input offers macOS" => [->(w, _r) { CompatibilityWorkflowTest.triggers(w)["workflow_dispatch"]["inputs"]["os"]["options"] << "macos-15" }, "the plan's runner images"],
    "the workflow_call scope is optional" => [->(w, _r) { CompatibilityWorkflowTest.triggers(w)["workflow_call"]["inputs"]["scope"]["required"] = false }, "scope input must be required"],
    "an input stops reaching the plan" => [->(w, _r) { w["jobs"]["plan"]["steps"].each { |s| s["env"]&.delete("RUBY") } }, "plan: the ruby input must reach the plan"],
    "an input is used inline in a script" => [->(w, _r) { w["jobs"]["plan"]["steps"].last["run"] = 'ruby scripts/ci-plan plan --ruby "${{ inputs.ruby }}"' }, "only through env"],
    "a macOS runner is added" => [->(w, _r) { w["jobs"]["extra"] = {"runs-on" => "macos-15"} }, "must not run on macOS"],
    "the release stops calling compatibility" => [->(_w, r) { r["jobs"]["compatibility"]["uses"] = "./.github/workflows/docs.yml" }, "a job must call compatibility.yml"],
    "the release asks for the edges" => [->(_w, r) { r["jobs"]["compatibility"]["with"]["scope"] = "edges" }, "must ask for scope full"],
    "the release prepares without waiting" => [->(_w, r) { r["jobs"]["prepare"].delete("needs") }, "prepare must wait for the full compatibility run"],
    "the upload skips the preparation" => [->(_w, r) { r["jobs"]["publish"]["needs"] = [] }, "publish must wait for the full compatibility run"]
  }.freeze

  SESSION_MUTATIONS = {
    "the session is not pinned to a commit" => [->(w, _r) { w["jobs"]["cell"]["steps"].each { |s| s["uses"] = "#{TMATE}@v3" if s["uses"].to_s.start_with?(TMATE) } }, "pinned to a full commit SHA"],
    "the session is open to every collaborator" => [->(w, _r) { w["jobs"]["cell"]["steps"].each { |s| s["with"]["limit-access-to-actor"] = false if s["uses"].to_s.start_with?(TMATE) } }, "limited to the actor"],
    "the session has no time limit of its own" => [->(w, _r) { w["jobs"]["development"]["steps"].each { |s| s.delete("timeout-minutes") if s["uses"].to_s.start_with?(TMATE) } }, "its own time limit"],
    "the session runs on every event" => [->(w, _r) { w["jobs"]["unsupported"]["steps"].each { |s| s["if"] = "${{ matrix.tmate == 'before-tests' }}" if s["uses"].to_s.start_with?(TMATE) } }, "only on a dispatch"],
    "the session runs on every job" => [->(w, _r) { w["jobs"]["cell"]["steps"].each { |s| s["if"] = "${{ github.event_name == 'workflow_dispatch' }}" if s["uses"].to_s.start_with?(TMATE) } }, "on the job the plan chose"],
    "the session moves to the report" => [->(w, _r) { w["jobs"]["report"]["steps"] << {"uses" => "#{TMATE}@#{'a' * 40}"} }, "report: a debugging session belongs only in the test jobs"],
    "a test job drops one session" => [->(w, _r) { w["jobs"]["cell"]["steps"].reject! { |s| s["name"] == "Open a tmate session after a failure" } }, "cell: must offer a session before the tests"],
    "a test job's time ignores the session" => [->(w, _r) { w["jobs"]["unsupported"]["timeout-minutes"] = 10 }, "give the debugging job more"],
    "the tmate input offers another mode" => [->(w, _r) { CompatibilityWorkflowTest.triggers(w)["workflow_dispatch"]["inputs"]["tmate"]["options"] = %w[off always] }, "the plan's modes"],
    "the tmate input defaults to a session" => [->(w, _r) { CompatibilityWorkflowTest.triggers(w)["workflow_dispatch"]["inputs"]["tmate"]["default"] = "before-tests" }, "default to off"],
    "the plan stops hearing the tmate input" => [->(w, _r) { w["jobs"]["plan"]["steps"].each { |s| s["env"]&.delete("TMATE") } }, "must pass the tmate input"],
    "a session returns to the release" => [->(_w, r) { r["jobs"]["publish"]["steps"] << {"uses" => "#{TMATE}@#{'a' * 40}"} }, "a release never opens a debugging session"]
  }.freeze

  def test_the_debugging_session_is_safe
    assert_equal [], self.class.session_problems(WORKFLOW, RELEASE)
  end

  def test_no_other_workflow_opens_a_session
    Dir[File.join(ROOT, ".github/workflows/*.yml")].each do |path|
      next if File.basename(path) == "compatibility.yml"

      refute_includes File.read(path), TMATE, path
    end
  end

  def test_a_session_mutation_is_reported
    SESSION_MUTATIONS.each do |description, (mutation, message)|
      workflow, release = mutate(&mutation)
      problems = self.class.session_problems(workflow, release)
      assert problems.any? { |problem| problem.include?(message) }, "#{description}: #{message} not in #{problems.inspect}"
    end
  end

  def test_a_mutation_is_reported
    MUTATIONS.each do |description, (mutation, message)|
      workflow, release = mutate(&mutation)
      problems = self.class.problems(workflow, release)
      assert problems.any? { |problem| problem.include?(message) }, "#{description}: #{message} not in #{problems.inspect}"
    end
  end

  def test_every_unsupported_check_has_a_version_check_arm_and_an_unknown_one_fails
    job = WORKFLOW.fetch("jobs").fetch("unsupported")
    script = job.fetch("steps").map { |step| step["run"] }.compact.find { |run| run.include?("case \"$VERSION_CHECK\"") }
    refute_nil script, "the unsupported job must select its test by check"
    arms = script.scan(/^\s*([\w.|*)]+)\)\s*$/).flatten.flat_map { |arm| arm.split("|") }
    MANIFEST.fetch("unsupported").map { |entry| entry.fetch("check") }.uniq.each { |check| assert_includes arms, check }
    assert_equal CIManifest::CHECKS.sort, MANIFEST.fetch("unsupported").map { |entry| entry.fetch("check") }.uniq.sort
    assert_match(/^\s*\*\)\n\s*echo [^\n]*>&2\n\s*exit 1 ;;/, script)
  end

  def test_supported_cells_and_the_development_build_name_their_lane
    %w[cell development].each do |name|
      assert_equal "supported", WORKFLOW.fetch("jobs").fetch(name).fetch("env").fetch("LIBTMUX_VERSION_CHECK_EXPECT"), name
    end
  end

  def test_no_job_runs_on_macos
    runners = WORKFLOW.fetch("jobs").values.map { |job| job.fetch("runs-on") }
    refute_empty runners
    runners.each { |runner| refute_match(/macos/i, runner.to_s) }
    assert_equal ["linux"], MANIFEST.fetch("systems")
    CIPlan::RUNNERS.each { |runner| refute_match(/macos/i, runner) }
  end

  def test_the_cell_names_follow_the_plan
    result = CIPlan.plan(MANIFEST, event: "workflow_dispatch", scope: "full")
    template = WORKFLOW.fetch("jobs").fetch("cell").fetch("name")
    names = result.fetch("cells").map do |cell|
      template.gsub(/\$\{\{ matrix\.(\w+) \}\}/) { cell.fetch(Regexp.last_match(1)) }
    end
    expected = CIPlan.job_names(result).grep(/\Alinux \//)
    assert_equal expected.sort, names.sort
  end

  def test_the_release_workflow_keeps_its_own_dry_run_and_the_push_check
    prepare = RELEASE.fetch("jobs").fetch("prepare")
    assert_includes prepare.fetch("steps").map { |step| step["run"].to_s }.join("\n"), "scripts/release-ci"
    assert_includes prepare.fetch("steps").map { |step| step["run"].to_s }.join("\n"), "release:dry_run"
  end
end
