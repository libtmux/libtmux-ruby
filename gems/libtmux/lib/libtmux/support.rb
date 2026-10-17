# frozen_string_literal: true

require "libtmux/errors"
require "libtmux/tmux_version"

module LibTmux
  # Here "support" means which tmux releases libtmux supports, not helper
  # code. Every server handle checks its daemon's release before any command
  # runs; this module exposes that check.
  module Support
    # The version check: is this tmux daemon supported at all?
    module Versions
      MINIMUM = Internal::TmuxVersion::MINIMUM

      module_function

      # Returns the release text when +value+ is a supported release and
      # raises UnsupportedFeatureError otherwise.
      def require_supported(value)
        Internal::TmuxVersion.require_supported(value).text
      end

      # The release text of the daemon behind +server+, such as "3.7d".
      def server_version(server)
        server.tmux_version
      end
    end

    MINIMUM = Versions::MINIMUM

    module_function

    def require_supported(value) = Versions.require_supported(value)

    def server_version(server) = Versions.server_version(server)
  end
end
