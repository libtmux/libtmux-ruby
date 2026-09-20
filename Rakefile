# frozen_string_literal: true

require "rake"

%w[unit mid integration packaging types outer].each do |mode|
  desc "Run the #{mode} verification loop"
  task(mode) { ruby "scripts/check", mode }
end

desc "Build all gem artifacts into pkg"
task :build do
  require "rubygems/package"
  require "fileutils"

  FileUtils.mkdir_p("pkg")
  Dir["gems/*/*.gemspec"].sort.each do |path|
    spec = Gem::Specification.load(path)
    artifact = File.expand_path("pkg/#{spec.full_name}.gem")
    Dir.chdir(File.dirname(path)) { Gem::Package.build(spec, false, true, artifact) }
  end
end

namespace :version do
  desc "Prepare all gem versions and the lockfile without publishing"
  task :bump, [:version] do |_, args|
    load "scripts/version"
    puts "Prepared #{VersionBump.new(__dir__).bump(args[:version])}"
  end
end

namespace :release do
  %w[prepare verify publish dry_run github].each do |operation|
    desc({"prepare" => "Build and retain the complete release artifact set",
      "verify" => "Verify retained release artifacts without network access",
      "publish" => "Publish verified artifacts from the trusted tag workflow",
      "github" => "Create or complete the GitHub prerelease from retained artifacts",
      "dry_run" => "Build, verify and test installed artifacts without uploading"}.fetch(operation))
    task operation, [:tag, :commit] do |_, args|
      require "open3"
      load "scripts/release" unless defined?(GemRelease)
      tag = args[:tag] || ENV.fetch("RELEASE_TAG")
      commit = args[:commit] || ENV["RELEASE_COMMIT"]
      unless commit
        commit, status = Open3.capture2("git", "rev-parse", "HEAD")
        abort "cannot resolve release commit" unless status.success?
        commit = commit.strip
      end
      if operation == "publish"
        load "scripts/release-ci" unless defined?(ReleaseCI)
        ReleaseCI.new.check(commit)
      end
      if operation == "github"
        load "scripts/release-github" unless defined?(GitHubRelease)
        release = GitHubRelease.new(__dir__)
        manifest = release.publish(tag: tag, commit: commit)
      else
        release = GemRelease.new(__dir__)
        manifest = release.public_send(operation == "dry_run" ? :prepare : operation, tag: tag, commit: commit)
      end
      if operation == "dry_run"
        sh({"LIBTMUX_RELEASE_DIR" => "pkg/release"}, Gem.ruby, "scripts/check", "packaging")
        release.verify(tag: tag, commit: commit)
      end
      puts "#{operation}: #{manifest.fetch('tag')} at #{manifest.fetch('commit')}"
    end
  end
end

task default: :mid
