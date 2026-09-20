# frozen_string_literal: true

module LibTmux
  module MCP
    class Resources
      def initialize(application:, endpoint_name:, enabled_tools:, max_response_bytes:)
        @application, @endpoint, @enabled, @max_bytes = application, endpoint_name, enabled_tools, max_response_bytes
      end

      def install(server)
        server.capabilities[:resources] = {subscribe: false, listChanged: false}
        if @enabled.include?("tmux_snapshot")
          prefix = "tmux://{endpoint}/{generation}/snapshots/{entity}"
          server.resource_templates.concat([
            ::MCP::ResourceTemplate.new(uri_template: prefix, name: "tmux_metadata", mime_type: "application/json",
              description: "Acquire metadata through tmux_snapshot with its default page limit. Encode every URI component; generation must match discovery. Reports capture interval and truncation."),
            ::MCP::ResourceTemplate.new(uri_template: "#{prefix}/pages/{cursor}", name: "tmux_metadata_page", mime_type: "application/json",
              description: "Read a retained tmux_snapshot page without refreshing it. Encode the cursor component; endpoint, generation and entity must match its captured query.")
          ])
        end
        if @enabled.include?("tmux_capture")
          server.resource_templates << ::MCP::ResourceTemplate.new(
            uri_template: "tmux://{endpoint}/{generation}/panes/{pane_id}/screen",
            name: "tmux_screen", mime_type: "text/plain",
            description: "Capture an exact pane through tmux_capture with its default byte/line bounds, without cursor tracking. Percent-encode pane IDs. Invalid UTF-8 is an application/octet-stream blob; _meta includes capture interval, truncation and unknown history continuity.")
        end
        server.resources_read_handler do |params, server_context: nil|
          read(params[:uri], cancellation: server_context&.cancellation)
        end
        server
      end

      private

      def decode(component)
        return unless component && component.match?(/\A(?:[A-Za-z0-9._~-]|%[0-9A-F]{2})+\z/)

        value = component.gsub(/%([0-9A-F]{2})/) { [$1.to_i(16)].pack("C") }.force_encoding(Encoding::UTF_8)
        return unless value.valid_encoding?

        encoded = value.bytes.map { |byte| (byte.chr.match?(/[A-Za-z0-9._~-]/) ? byte.chr : "%%%02X" % byte) }.join
        value if encoded == component
      end

      def read(uri, cancellation:)
        unless uri.is_a?(String) && uri.valid_encoding? && uri.bytesize <= 1024
          error("invalid_input", "The resource URI is invalid.", protocol: true)
        end
        match = /\Atmux:\/\/([^\/]+)\/([^\/]+)\/(snapshots|panes)\/([^\/]+)(?:\/(pages|screen)(?:\/([^\/]+))?)?\z/.match(uri)
        error("invalid_input", "The resource URI is invalid.", protocol: true) unless match
        endpoint, generation, collection, target, suffix, cursor = match.captures.map { |part| part && decode(part) }
        unless endpoint == @endpoint && generation && generation.bytesize <= 128 &&
            (!match[6] || cursor)
          error("invalid_input", "The resource URI is invalid.", protocol: true)
        end
        if collection == "snapshots" && Internal::Catalog.kinds.map(&:to_s).include?(target) &&
            (suffix.nil? || (suffix == "pages" && cursor))
          name = "tmux_snapshot"
          arguments = cursor ? {"cursor" => cursor} : {"entity" => target}
        elsif collection == "panes" && target&.match?(/\A%[0-9]+\z/) && suffix == "screen" && cursor.nil?
          name = "tmux_capture"
          arguments = {"target" => {"generation" => generation, "kind" => "pane", "id" => target}}
        else
          error("invalid_input", "The resource URI is invalid.", protocol: true)
        end
        response = @application.call(name, arguments, cancellation: cancellation).structured_content
        unless response.fetch("ok")
          failure = response.fetch("error")
          error(failure.fetch("code"), failure.fetch("message"), details: failure)
        end
        data = response.fetch("data")
        if name == "tmux_snapshot"
          unless data.fetch("server_identity").fetch("generation") == generation && data.fetch("entity") == target
            error("stale_target", "The resource generation or captured entity does not match.", delivery: "observed")
          end
          contents = [{uri: uri, mimeType: "application/json", text: JSON.generate(response)}]
        else
          metadata = data.reject { |key, _| key == "rows" }
          contents = [{uri: uri, _meta: {"io.github.libtmux/capture" => metadata}}]
          if data.fetch("encoding") == "utf-8"
            contents.first.merge!(mimeType: "text/plain", text: data.fetch("rows").join)
          else
            bytes = data.fetch("rows").map { |row| row.unpack1("m0") }.join
            contents.first.merge!(mimeType: "application/octet-stream", blob: [bytes].pack("m0"))
          end
        end
        if JSON.generate(contents).bytesize > @max_bytes
          error("capacity", "The resource exceeds its response byte limit.", delivery: "observed")
        end
        contents
      end

      def error(code, message, protocol: false, details: nil, delivery: "not_sent")
        raise ::MCP::Server::RequestHandlerError.new(message, nil,
          error_code: protocol ? -32602 : -32000,
          error_data: details || {"code" => code, "message" => message, "delivery" => delivery})
      end
    end
    private_constant :Resources
  end
end
