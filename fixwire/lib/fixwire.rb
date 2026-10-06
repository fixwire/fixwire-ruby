# frozen_string_literal: true

require_relative "fixwire/version"
require_relative "fixwire/types"
require_relative "fixwire/dsn"
require_relative "fixwire/options"
require_relative "fixwire/scope"
require_relative "fixwire/span"
require_relative "fixwire/hub"
require_relative "fixwire/frames"
require_relative "fixwire/budget"
require_relative "fixwire/internal/redaction"
require_relative "fixwire/otlp"
require_relative "fixwire/transport"
require_relative "fixwire/client"
require_relative "fixwire/requests"
require_relative "fixwire/rack"
require_relative "fixwire/instrumentation"

# The Fixwire SDK for Ruby: errors with their causes, traces, release health, cron monitors and
# feedback, sent over the Fixwire protocol (OpenTelemetry's OTLP/HTTP plus a few JSON endpoints).
#
#   Fixwire.init(dsn: "https://fw_pk_live_…@ingest.eu.fixwire.io", release: "shop@1.4.0")
#
# Without a DSN (and without FIXWIRE_DSN) the SDK does nothing.
module Fixwire
  class << self
    # Starts the SDK: from keywords, a block, or both. Returns the client.
    def init(**)
      opts = Options.new(**)
      yield opts if block_given?
      client = Client.new(opts)
      Hub.main = Hub.new(client, Hub.main&.scope&.dup || Scope.new)
      Hub.current = Hub.main
      if client.enabled?
        Instrumentation.install(opts)
        install_at_exit
      end
      client
    end

    def client = Hub.current.client
    def initialized? = client&.enabled? == true
    def hub = Hub.current

    # Sends an exception and its causes; its event id, or nil when not sent.
    def capture_exception(exception, level: nil)
      Hub.current.capture_exception(exception, level: Fixwire.level(level))
    end

    # Sends a message (at the scope's level, else info); its event id, or nil when not sent.
    def capture_message(message, level: nil) = Hub.current.capture_message(message, level: level)

    def capture_event(event) = Hub.current.capture_event(event)

    # The id of the last event sent, such as for a feedback form after a crash.
    def last_event_id = Hub.last_event_id

    # Records something that happened: a Breadcrumb, or its fields as keywords.
    def add_breadcrumb(breadcrumb = nil, **fields)
      guard("adding a breadcrumb") do
        breadcrumb ||= Breadcrumb.new(**fields, level: Fixwire.level(fields[:level]))
        Hub.current.add_breadcrumb(breadcrumb)
      end
    end

    def configure_scope = yield(Hub.current.scope)

    # Runs a block with a copy of the current scope: what it sets there is gone afterwards.
    def with_scope(&) = Hub.current.with_scope(&)

    # A User, a Hash (id:, email:, username:) or an id.
    def set_user(user) = guard("setting the user") { Hub.current.scope.set_user(user) }
    def set_tag(key, value) = guard("setting a tag") { Hub.current.scope.set_tag(key, value) }
    def set_context(name, values) = guard("setting a context") { Hub.current.scope.set_context(name, values) }
    def set_extra(key, value) = guard("setting an extra") { Hub.current.scope.set_extra(key, value) }

    # Starts a span under the current one (or a new trace), current until it finishes.
    def start_span(name, op: nil, attributes: {}) = Hub.current.start_span(name, op: op, attributes: attributes)

    # Runs a block in a span; an exception fails the span and goes on.
    def trace(name, op: nil, attributes: {})
      span = Hub.current.start_span(name, op: op, attributes: attributes)
      begin
        yield span
      rescue Exception => e # rubocop:disable Lint/RescueException -- marked, then raised on
        span.set_error(e)
        raise
      ensure
        span.finish
      end
    end

    # Starts a span that continues a caller's trace, from its W3C headers.
    def continue_trace(traceparent, tracestate, baggage, name, op: nil, attributes: {})
      Hub.current.continue_trace(traceparent, tracestate, baggage, name, op: op, attributes: attributes)
    end

    def current_span = Hub.current.span

    # Reports a run of a scheduled job: :in_progress when it starts, then :ok or :error with the
    # returned id. The first check-in creates the monitor from config.
    def capture_check_in(monitor, status, id: nil, duration: nil, config: nil)
      Hub.current.capture_check_in(monitor, status, id: id, duration: duration, config: config)
    end

    # Runs a job as a run of a monitor: in progress, then ok, or error when it raises (and the
    # exception goes on).
    def with_monitor(monitor, config = nil)
      id = capture_check_in(monitor, :in_progress, config: config)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = :error
      result = yield
      status = :ok
      result
    ensure
      capture_check_in(monitor, status, id: id, duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) if id
    end

    # Sends what someone said about an error or an AI answer: message:, score: (-1..1), trace_id:,
    # event_id:, name:, email:, url:, source:. Its id, or nil when it holds neither message nor score.
    def capture_feedback(**feedback) = Hub.current.capture_feedback(**feedback)

    # Sends what was captured and waits for it, at most timeout seconds; false when something was
    # left unsent.
    def flush(timeout = 2.0) = Hub.current.flush(timeout)

    # @api private
    def sdk = { "name" => SDK_NAME, "version" => VERSION }

    # @api private runs a block as the SDK's own work on this thread (or fiber): what a logging
    # integration sees meanwhile (an app's callback logging, say) is not recorded. Only the
    # outermost call clears the mark.
    def busy
      return yield if Thread.current[:__fixwire_busy]

      begin
        Thread.current[:__fixwire_busy] = true
        yield
      ensure
        Thread.current[:__fixwire_busy] = nil
      end
    end

    # @api private runs an entry point's block; what fails there is said in the debug log, not
    # raised into the app.
    def guard(what)
      yield
    rescue StandardError => e
      Hub.main&.client&.log("#{what} failed: #{e.message}")
      nil
    end

    private

    # At exit: the exception that ends the process, as a crash, then what is left.
    def install_at_exit
      return if @at_exit

      @at_exit = true
      at_exit do
        error = $! # rubocop:disable Style/SpecialGlobalVars -- the exception ending the process
        client = Hub.main&.client
        if client&.enabled?
          if client.options.capture_uncaught && error && !error.is_a?(SystemExit) && !error.is_a?(SignalException) &&
             !client.captured?(error)
            Hub.current.capture_exception(error, mechanism: "uncaught", handled: false, level: :fatal)
          end
          client.flush(client.options.shutdown_timeout)
        end
      end
    end
  end
end
