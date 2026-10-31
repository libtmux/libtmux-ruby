# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "open3"
require "tmpdir"

load File.expand_path("../../scripts/ci-plan", __dir__)

# scripts/build-tmux against a local repository whose "build" installs a tmux
# that reports the contents of VERSION, so no network and no compiler runs.
class BuildTmuxTest < Minitest::Test
  SCRIPT = File.expand_path("../../scripts/build-tmux", __dir__)
  GIT = {"GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL,
         "GIT_AUTHOR_NAME" => "test", "GIT_AUTHOR_EMAIL" => "test@example.com",
         "GIT_COMMITTER_NAME" => "test", "GIT_COMMITTER_EMAIL" => "test@example.com"}.freeze
  CONFIGURE = <<~'SH'
    #!/bin/sh
    prefix="${1#--prefix=}"
    printf '#!/bin/sh\necho tmux %s\n' "$(cat VERSION)" > tmux
    chmod +x tmux
    printf 'all:\n\t@true\ninstall:\n\tmkdir -p %s/bin\n\tcp tmux %s/bin/tmux\n' "$prefix" "$prefix" > Makefile
  SH

  def git(directory, *arguments)
    output, status = Open3.capture2e(GIT, "git", "-C", directory, *arguments)
    raise "git #{arguments.join(' ')}: #{output}" unless status.success?

    output.strip
  end

  def setup
    @directory = Dir.mktmpdir("libtmux-ruby-build-tmux-")
    @repository = File.join(@directory, "tmux")
    Dir.mkdir(@repository)
    git(@repository, "init", "-q", "--initial-branch=master")
    File.write(File.join(@repository, "autogen.sh"), "exit 0\n")
    File.write(File.join(@repository, "configure"), CONFIGURE)
    File.chmod(0o755, File.join(@repository, "configure"))
    @commits = {}
    [["one", %w[v1 3.6b]], ["two", []]].each do |version, tags|
      File.write(File.join(@repository, "VERSION"), "#{version}\n")
      git(@repository, "add", "--all")
      git(@repository, "commit", "-q", "-m", version)
      @commits[version] = git(@repository, "rev-parse", "HEAD")
      tags.each { |tag| git(@repository, "tag", tag) }
    end
    git(@repository, "branch", "shadow")
    git(@repository, "tag", "shadow", @commits["one"])
    @root = File.join(@directory, "build")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def build(ref)
    environment = {"LIBTMUX_TMUX_REPOSITORY" => "file://#{@repository}", "LIBTMUX_TMUX_BUILD_ROOT" => @root}
    stdout, stderr, status = Open3.capture3(environment, "bash", SCRIPT, ref)
    [status, stdout.lines.to_h { |line| line.chomp.split("=", 2) }, stderr]
  end

  def test_a_tag_builds_its_commit_not_the_branch_head
    status, result, error = build("v1")
    assert status.success?, error
    assert_equal ["one", @commits["one"]], result.values_at("version", "commit")
    assert_equal File.join(@root, "install-#{@commits['one']}/bin/tmux"), result.fetch("binary")
    assert File.executable?(result.fetch("binary"))
  end

  def test_a_branch_builds_its_head
    status, result, error = build("master")
    assert status.success?, error
    assert_equal ["two", @commits["two"]], result.values_at("version", "commit")
  end

  def test_a_tag_wins_over_a_branch_of_the_same_name
    status, result, error = build("shadow")
    assert status.success?, error
    assert_equal @commits["one"], result.fetch("commit")
  end

  def test_a_full_commit_builds_that_commit
    status, result, error = build(@commits["one"])
    assert status.success?, error
    assert_equal ["one", @commits["one"]], result.values_at("version", "commit")
  end

  def test_the_build_is_named_for_the_commit_never_the_ref
    build("master")
    assert_equal ["install-#{@commits['two']}", "source-#{@commits['two']}"], Dir.children(@root).sort
  end

  def test_a_second_build_reuses_the_install
    _, first, = build("v1")
    File.write(File.join(@root, "source-#{@commits['one']}", "configure"), "#!/bin/sh\nexit 1\n")
    status, second, error = build("v1")
    assert status.success?, error
    assert_equal first, second
  end

  def test_an_unknown_ref_is_refused
    status, _, error = build("nowhere")
    refute status.success?
    assert_match(/is not a tag, a branch or a full commit/, error)
  end

  def test_an_unusable_ref_is_refused_before_anything_is_fetched
    ["-upload-pack=x", "a;b", "a b", "a..b", "a1b2c3d", "topic/", "x.lock", "x" * 65].each do |ref|
      status, _, error = build(ref)
      refute status.success?, ref
      assert_match(/not a usable tmux ref/, error, ref)
    end
    refute File.exist?(@root)
  end

  def test_the_script_and_the_plan_accept_the_same_refs
    accepted = ["3.6b", "next-3.9", "master", "release_3.7d", "feature/x", "a" * 40]
    rejected = ["", "-x", "a;b", "$(id)", "a..b", "a1b2c3d", "a" * 39, "topic/", "x.lock", "x" * 65]
    accepted.each { |ref| assert_equal ref, CIPlan.check_ref(ref) }
    rejected.each { |ref| assert_raises(CIPlan::Error, ref.inspect) { CIPlan.check_ref(ref) } }
    (accepted - ["a" * 40]).each do |ref|
      _, _, error = build(ref)
      refute_match(/not a usable tmux ref/, error, ref)
    end
    rejected.reject(&:empty?).each do |ref|
      _, _, error = build(ref)
      assert_match(/not a usable tmux ref/, error, ref)
    end
  end
end
