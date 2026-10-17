# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"

class TmuxVersionTest < Minitest::Test
  Report = Struct.new(:stdout, :stderr, :ok, keyword_init: true) do
    def success?
      ok
    end

    def pid
      nil
    end

    def delivery
      :observed
    end
  end

  def version
    LibTmux::Internal::TmuxVersion
  end

  def test_patch_letters_are_part_of_the_minimum
    %w[0.9 2.9a 3.2a 3.3 3.3-rc1 3.3-rc].each do |value|
      assert_raises(LibTmux::UnsupportedFeatureError, value) { version.require_supported(value) }
    end
    %w[3.3a 3.3b 3.4 3.7d 3.10 4.0 next-3.8 next-3.9 3.8-rc 3.8-rc2].each do |value|
      assert_equal value, version.require_supported(value).text
    end
  end

  def test_development_builds_and_candidates_rank_below_their_release
    assert version.parse("3.8").stable?
    %w[next-3.8 3.8-rc 3.8-rc2].each do |value|
      refute version.parse(value).stable?
      assert_operator version.parse(value), :<, version.parse("3.8")
    end
    assert_operator version.parse("3.7d"), :<, version.parse("next-3.8")
    assert_operator version.parse("3.3"), :<, version.parse("3.3a")
    assert_operator version.parse("3.9"), :<, version.parse("3.10")
  end

  # The forms tmux has reported, shared by every port. Supported releases rank
  # at or above 3.3a; the rest are below the floor or not release numbers.
  GRAMMAR = {
    accept: %w[3.3a 3.4 3.7d 3.8 3.10 4.0 3.4-rc 3.8-rc 3.8-rc2 next-3.4 next-3.9],
    below_floor: %w[3.3 3.2a 3.3-rc 3.2-rc5 next-3.3],
    unparseable: ["master", "openbsd-7.6", "", "3", "garbage", "3.3a garbage", "3.3a-master", "3.3a-dev", "next-3.3a",
      "next-3.9-master", "next-3.9a", "3.8a-rc2", "3.8-rcx", "3.8-RC2", "3.8-rc-2"]
  }.freeze
  ORDER = [%w[next-3.7 3.7-rc 3.7-rc3 3.7 3.7a], %w[next-3.4 3.4-rc 3.4], %w[3.8-rc 3.8-rc2 3.8 3.8a 3.9], %w[3.9 3.10 4.0]].freeze

  def test_version_grammar_vectors
    GRAMMAR.fetch(:accept).each { |value| assert_equal value, version.require_supported(value).text, value }
    GRAMMAR.fetch(:below_floor).each do |value|
      assert_equal value, version.parse(value).text
      assert_raises(LibTmux::UnsupportedFeatureError, value) { version.require_supported(value) }
    end
    GRAMMAR.fetch(:unparseable).each do |value|
      error = assert_raises(LibTmux::UnsupportedFeatureError, value.inspect) { version.parse(value) }
      assert_match(/unrecognized/, error.message)
    end
    ORDER.each do |chain|
      chain.each_cons(2) { |lower, higher| assert_operator version.parse(lower), :<, version.parse(higher), "#{lower} < #{higher}" }
    end
    assert version.parse("3.7d").stable?
    refute version.parse("3.8-rc").stable?
    assert version.parse("3.7").exactly?(3, 7)
    refute version.parse("3.7a").exactly?(3, 7)
    refute version.parse("3.7-rc").exactly?(3, 7)
  end

  def test_the_floor_itself_is_met_only_by_its_release
    version.require_supported("3.3a")
    %w[next-3.3a 3.3a-rc1].each do |value|
      assert_raises(LibTmux::UnsupportedFeatureError, value) { version.require_supported(value) }
    end
  end

  def test_unrecognized_reports_fail_closed
    ["master", "openbsd-7.5", "openbsd-3.9", "next-master", "3.4garbage", "3.7beta", "3.3a-unknown", "3.3A", "3.3aa", "3", "tmux 3.3a", "3.3a\n", " 3.3a", "3.3a\0", "", nil, 3.4].each do |value|
      error = assert_raises(LibTmux::UnsupportedFeatureError, value.inspect) { version.require_supported(value) }
      assert_equal :admission, error.phase
      assert_equal :not_sent, error.delivery
    end
  end

  def test_executable_report_accepts_tmux_and_the_executable_name
    path = "/tmp/selected tmux"
    [["tmux 3.3a\n", path], ["selected tmux 3.3a\n", path], ["tmux-3.3a 3.3a\n", "/tmp/tmux-3.3a"],
      ["selected-\xFF 3.7d\n".b, "/tmp/selected-\xFF".b]].each do |stdout, selected|
      release = version.executable(selected) { Report.new(stdout: stdout, stderr: "", ok: true) }
      assert_equal stdout.split.last, release.text
    end
  end

  def test_executable_report_refuses_old_malformed_and_failed_reports
    path = "/tmp/selected"
    ["tmux 3.3\n", "tmux 3.2a\n", " tmux 3.3a\n", "other 3.3a\n", "tmux 3.3a\nextra\n", "tmux\n", "", "tmux 3.4garbage\n"].each do |stdout|
      error = assert_raises(LibTmux::UnsupportedFeatureError, stdout) do
        version.executable(path) { Report.new(stdout: stdout, stderr: "", ok: true) }
      end
      assert_equal :not_sent, error.delivery
    end
    error = assert_raises(LibTmux::CommandError) { version.executable(path) { Report.new(stdout: "", stderr: "x", ok: false) } }
    assert_equal :not_sent, error.delivery
  end

  def test_connected_probe_reads_the_version_from_the_private_marker_error
    argv = nil
    release = version.connected(["tmux", "-N", "-S", "route"]) do |command|
      argv = command
      marker = command.last.delete_suffix('#{version}')
      Report.new(stdout: "", stderr: "unknown command: #{marker}3.7d\n", ok: false)
    end
    assert_equal "3.7d", release.text
    assert_equal ["tmux", "-N", "-S", "route", "run-shel", "-C"], argv.first(6)
    assert_match(/\Alibtmux-version-\h{32}-\#\{version\}\z/, argv.last)
  end

  def test_connected_probe_refuses_an_older_daemon_before_effects
    error = assert_raises(LibTmux::UnsupportedFeatureError) do
      version.connected(["tmux"]) do |command|
        Report.new(stdout: "", stderr: "unknown command: #{command.last.delete_suffix('#{version}')}3.3\n", ok: false)
      end
    end
    assert_match(/3\.3a or newer is required \(connected version 3\.3\)/, error.message)
    assert_equal :not_sent, error.delivery
  end

  def test_connected_probe_separates_an_absent_server_from_other_failures
    ["no server running on /tmp/route\n", "error connecting to /tmp/route (No such file or directory)\n",
      "error connecting to /tmp/route (Connection refused)\n"].each do |stderr|
      error = assert_raises(LibTmux::TargetNotFoundError, stderr) do
        version.connected(["tmux"]) { Report.new(stdout: "", stderr: stderr, ok: false) }
      end
      assert_equal :not_sent, error.delivery
    end
    [["", "error connecting to /tmp/route (Permission denied)\n", false], ["3.3a\n", "", true],
      ["", "unknown command: other3.3a\n", false], ["", "", true]].each do |stdout, stderr, ok|
      error = assert_raises(LibTmux::CommandError, stderr) do
        version.connected(["tmux"]) { Report.new(stdout: stdout, stderr: stderr, ok: ok) }
      end
      assert_equal :not_sent, error.delivery
      assert_equal :admission, error.phase
    end
  end

  def test_probe_failures_keep_their_class_but_report_no_dispatch
    error = assert_raises(LibTmux::DeadlineExceeded) do
      version.connected(["tmux"]) { raise LibTmux::DeadlineExceeded.new("slow", delivery: :possibly_sent, phase: :read, pid: 7) }
    end
    assert_equal [:not_sent, :admission, 7], [error.delivery, error.phase, error.pid]
  end

  def test_fence_names_the_exact_release_and_a_private_marker
    release = version.parse("3.7d")
    fence, marker = version.fence(release)
    assert_equal ["if-shel", "-F", '#{==:#{version},3.7d}', "", marker, ";"], fence
    assert_match(/\Alibtmux-version-\h{32}\z/, marker)
    refute_equal marker, version.fence(release).last
  end

  def test_fence_failure_is_recognized_only_as_the_marker_error_line
    release = version.parse("3.7d")
    marker = "libtmux-version-#{'a' * 32}"
    refused = Report.new(stdout: "", stderr: "unknown command: #{marker}\n", ok: false)
    error = assert_raises(LibTmux::UnsupportedFeatureError) { version.check_fence(refused, marker, release) }
    assert_equal [:not_sent, :admission], [error.delivery, error.phase]
    [Report.new(stdout: "", stderr: "", ok: true), Report.new(stdout: "", stderr: "unknown command: #{marker}x\n", ok: false),
      Report.new(stdout: "unknown command: #{marker}\n", stderr: "", ok: true)].each do |result|
      assert_same result, version.check_fence(result, marker, release)
    end
  end

  def test_fence_self_check_accepts_only_the_marker_error_from_the_real_commands
    argv, marker = version.fence_check_argv
    assert_equal ["if-shel", "-F", "1", "run-shel -C #{marker}"], argv
    good = Report.new(stdout: "", stderr: "unknown command: #{marker}\n", ok: false)
    assert_same good, version.verify_fence(good, marker)
    ["", "command display-message: too many arguments (need at most 1)\n", "ambiguous command: if-shel\n",
      "unknown command: #{marker}\nextra\n"].each do |stderr|
      error = assert_raises(LibTmux::UnsupportedFeatureError, stderr) do
        version.verify_fence(Report.new(stdout: "", stderr: stderr, ok: false), marker)
      end
      assert_equal [:not_sent, :admission], [error.delivery, error.phase]
    end
    assert_raises(LibTmux::UnsupportedFeatureError) { version.verify_fence(Report.new(stdout: "", stderr: "unknown command: #{marker}\n", ok: true), marker) }
  end

  def test_identity_fields_travel_as_one_comma_joined_word
    argv, marker = version.identity_argv(%w[version pid start_time])
    assert_equal ["run-shel", "-C", "#{marker}\#{version},\#{pid},\#{start_time}"], argv
    result = Report.new(stdout: "", stderr: "unknown command: #{marker}3.7d,41,1700000000\n", ok: false)
    assert_equal %w[3.7d 41 1700000000], version.parse_identity(result, marker, 3)
  end

  def test_identity_reports_that_are_not_one_complete_word_are_refused
    _, marker = version.identity_argv(%w[version pid])
    [["unknown command: #{marker}3.7d,41\nunknown command: x\n", false], ["unknown command: #{marker}3.7d 41\n", false],
      ["unknown command: #{marker}3.7d\n", false], ["unknown command: other3.7d,41\n", false],
      ["unknown command: #{marker}3.7d,41\n", true], ["", false]].each do |stderr, ok|
      assert_raises(LibTmux::ProtocolError, stderr) do
        version.parse_identity(Report.new(stdout: "", stderr: stderr, ok: ok), marker, 2)
      end
    end
    assert_raises(LibTmux::ProtocolError) do
      version.parse_identity(Report.new(stdout: "x", stderr: "unknown command: #{marker}3.7d,41\n", ok: false), marker, 2)
    end
  end
end
