# frozen_string_literal: true

require "libtmux"

endpoint = LibTmux::Endpoint.new
result = LibTmux::Server.discover(roots: [File.dirname(endpoint.socket_path)])
puts "servers: #{result.servers.length}"
raise "discovery was truncated" if result.truncated?
