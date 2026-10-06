# frozen_string_literal: true

module Fixwire
  module Rack
    # Rack middleware: each request in a scope of its own, a server span named after its route
    # that continues the caller's trace, its session, and the exceptions that escape the app (or
    # that a framework turned into a 500) as crashes.
    #
    #   use Fixwire::Rack::Middleware
    #
    # The route comes from the framework when it says (Sinatra's "sinatra.route", Rails's
    # "action_dispatch.route_uri_pattern") or from env["fixwire.route"].
    class Middleware
      def initialize(app, mechanism: "rack")
        @app = app
        @mechanism = mechanism
      end

      def call(env)
        hub = Hub.current
        return @app.call(env) unless hub.enabled?

        hub.with_scope do
          tracked = ServerRequest.start(hub, env["REQUEST_METHOD"], url(env), headers(env), client_address: client_address(env))
          tracked.request.route_provider = -> { Middleware.route(env) }
          env["fixwire.server_request"] = tracked
          begin
            status, response_headers, body = @app.call(env)
          rescue Exception => e # rubocop:disable Lint/RescueException -- reported, then raised on
            capture(hub, e)
            tracked.route = Middleware.route(env)
            tracked.finish(500)
            raise
          end
          # A framework that rescued an exception and answered 500 leaves it here.
          error = env["sinatra.error"] || env["rack.exception"] || env["action_dispatch.exception"]
          capture(hub, error) if error.is_a?(Exception) && status.to_i >= 500
          tracked.route = Middleware.route(env)
          tracked.finish(status)
          [status, response_headers, body]
        end
      end

      # The route the request matched, without Rails's optional format.
      def self.route(env)
        route = env["fixwire.route"] || env["action_dispatch.route_uri_pattern"]
        return route.sub("(.:format)", "") if route

        env["sinatra.route"]&.split(" ", 2)&.last
      end

      private

      def capture(hub, exception)
        hub.capture_exception(exception, mechanism: @mechanism, handled: false) unless hub.client.captured?(exception)
      end

      def url(env)
        scheme = env["rack.url_scheme"] || "http"
        port = env["SERVER_PORT"].to_s
        host = env["HTTP_HOST"] || (["", "80", "443"].include?(port) ? env["SERVER_NAME"] : "#{env["SERVER_NAME"]}:#{port}")
        query = env["QUERY_STRING"].to_s.empty? ? "" : "?#{env["QUERY_STRING"]}"
        "#{scheme}://#{host}#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}#{query}"
      end

      def headers(env)
        env.each_with_object({}) do |(key, value), out|
          next unless value.is_a?(String)

          if key.start_with?("HTTP_")
            out[key[5..].downcase.tr("_", "-")] = value
          elsif %w[CONTENT_TYPE CONTENT_LENGTH].include?(key)
            out[key.downcase.tr("_", "-")] = value
          end
        end
      end

      def client_address(env)
        forwarded = env["HTTP_X_FORWARDED_FOR"].to_s.split(",").first&.strip
        forwarded.to_s.empty? ? env["REMOTE_ADDR"] : forwarded
      end
    end
  end
end
