# frozen_string_literal: true

require_relative "support/sandbox"
require "minitest/autorun"

Dir[File.expand_path("../gems/*/lib", __dir__)].sort.reverse_each do |path|
  $LOAD_PATH.unshift(path)
end
