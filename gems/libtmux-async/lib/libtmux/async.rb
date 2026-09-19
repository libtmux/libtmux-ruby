# frozen_string_literal: true

require "libtmux"
require "async"
require "libtmux/async/version"
require "libtmux/async/server"
require "libtmux/async/scope"
require "libtmux/async/control"

module LibTmux
  module Async
    module CleanupDetails
      attr_reader :async_cleanup_errors
    end
    private_constant :CleanupDetails

    def self.attach_cleanup(error, details)
      return if details.empty?

      if error.is_a?(Error)
        error.__send__(:attach_cleanup_errors, details)
      else
        error.extend(CleanupDetails)
        error.instance_variable_set(:@async_cleanup_errors, ((error.async_cleanup_errors || []) + details).freeze)
      end
    rescue FrozenError, TypeError
      nil
    end
    private_class_method :attach_cleanup

    def self.open(server:, parent: ::Async::Task.current, **options)
      raise ArgumentError, "Async scope requires a block" unless block_given?

      scope = Scope.new(parent: parent, server: server, **options)
      failure = result = nil
      begin
        result = yield scope
      rescue Exception => error
        failure = error
      ensure
        begin
          scope.close
        rescue Exception => error
          details = ["Async scope close failed (#{error.class})"]
          details.concat(error.cleanup_errors) if error.is_a?(Error)
          attach_cleanup(failure, details) if failure
          failure ||= error
        end
      end
      raise failure if failure

      result
    end
  end
end
