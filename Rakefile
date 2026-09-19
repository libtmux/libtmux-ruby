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

task default: :mid
