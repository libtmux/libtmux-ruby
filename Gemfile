# frozen_string_literal: true

source "https://rubygems.org"

%w[libtmux libtmux-async libtmux-mcp libtmux-workspace].each { |name| gemspec path: "gems/#{name}" }

group :test do
  gem "fcntl", "~> 1.3"
  gem "fiddle", "~> 1.1"
  gem "fileutils", "~> 1.8"
  gem "minitest", "~> 6.0"
  gem "open3", "~> 0.2"
end

gem "rake", "~> 13.3"
gem "rbs", "~> 3.10"
gem "yard", "~> 0.9"

group :development do
  gem "syntax_tree", "~> 6.3"
end
