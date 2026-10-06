# frozen_string_literal: true

require "net/http"

module Fixwire
  # @api private Net::HTTP requests as client spans and http breadcrumbs, with trace headers to the
  # trace propagation targets. The SDK's own requests are left alone.
  module NetHTTP
    def request(req, body = nil, &)
      return super if Thread.current[:__fixwire_sending] || started_tracing?

      hub = Hub.current
      return super unless hub.enabled? && hub.client.options.trace_net_http

      url = "#{use_ssl? ? "https" : "http"}://#{address}#{":#{port}" unless [80, 443].include?(port)}#{req.path}"
      outgoing = OutgoingRequest.start(hub, req.method, url) { |name, value| req[name] = value unless req[name] }
      begin
        @__fixwire_tracing = true
        response = super
      rescue StandardError => e
        outgoing.fail(e)
        raise
      ensure
        @__fixwire_tracing = false
      end
      outgoing.finish(response.code.to_i)
      response
    end

    private

    # Net::HTTP#request calls itself again when it has to start the connection first.
    def started_tracing? = @__fixwire_tracing == true
  end

  # @api private ::Logger records (Rails's too) from INFO as breadcrumbs: hooked where Logger
  # formats a record it writes, so a block's message is evaluated once, as Logger does. Only when
  # the app loaded ::Logger: from Ruby 3.5 it is a gem of its own.
  module LoggerBreadcrumbs
    LEVELS = { "INFO" => :info, "WARN" => :warning, "ERROR" => :error, "FATAL" => :fatal, "ANY" => :error }.freeze

    # A record logged while one is being kept (by before_breadcrumb, say) is left alone, and only
    # the outer call clears the mark: an inner one clearing it would let the recursion go on.
    def self.record(severity, progname, message)
      level = LEVELS[severity.to_s]
      return if level.nil? || message.is_a?(Exception) || Thread.current[:__fixwire_logging]

      begin
        Thread.current[:__fixwire_logging] = true
        hub = Hub.current
        return unless hub.enabled? && hub.client.options.breadcrumbs_logger

        text = message.is_a?(String) ? message : message.inspect
        category = progname.is_a?(String) && !progname.empty? ? progname : "log"
        hub.add_breadcrumb(Breadcrumb.new(category: category, message: text.strip, level: level, type: "log"))
      ensure
        Thread.current[:__fixwire_logging] = nil
      end
    rescue StandardError
      nil
    end

    private

    def format_message(severity, datetime, progname, message)
      Fixwire::LoggerBreadcrumbs.record(severity, progname, message)
      super
    end
  end

  # @api private a Rake task's exception, as a crash: Rake rescues it, prints it and exits, so
  # nothing else sees it.
  module RakeErrors
    def display_error_message(exception)
      hub = Hub.current
      if hub.enabled? && !hub.client.captured?(exception)
        hub.with_scope do |scope|
          scope.set_transaction("rake #{top_level_tasks.join(" ")}".strip)
          hub.capture_exception(exception, mechanism: "rake", handled: false)
        end
      end
      super
    end
  end

  # @api private installs the instrumentation the options ask for, once.
  module Instrumentation
    def self.install(options)
      ::Rake::Application.prepend(RakeErrors) if defined?(::Rake::Application) && !(::Rake::Application < RakeErrors)
      Net::HTTP.prepend(NetHTTP) if options.trace_net_http && !(Net::HTTP < NetHTTP)
      ::Logger.prepend(LoggerBreadcrumbs) if options.breadcrumbs_logger && defined?(::Logger) && !(::Logger < LoggerBreadcrumbs)
    end
  end
end
