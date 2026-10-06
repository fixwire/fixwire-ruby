# frozen_string_literal: true

require "fixwire"

Fixwire::Frames.sdk_dirs << File.expand_path("..", __dir__)

module Fixwire
  # Fixwire in a Rails app (7.1 and later): the Railtie sets it up from FIXWIRE_* environment
  # variables or from Fixwire.init in config/initializers/fixwire.rb, with Rails's environment and
  # root as defaults.
  module Rails
    class << self
      # Who is signed in, read only when an event or a session needs it: ->(env) { a user object,
      # a Hash or an id }. By default Current.user (Rails's authentication generator), else Warden's
      # (Devise) user.
      attr_writer :user

      def user = @user ||= method(:default_user)

      # @api private a user object as Fixwire sends it: its id, and its email with send_default_pii
      def user_from(object, pii)
        case object
        when nil, Fixwire::User, Hash, String, Integer then Fixwire::User.from(object)
        else
          id = object.respond_to?(:id) ? object.id : object.to_s
          email = object.email if pii && object.respond_to?(:email)
          Fixwire::User.new(id: id&.to_s, email: email)
        end
      end

      private

      def default_user(env)
        current = ::Current.user if defined?(::Current) && ::Current.respond_to?(:user)
        current || env["warden"]&.user(run_callbacks: false)
      rescue StandardError
        nil
      end
    end

    # Each request: Fixwire's Rack middleware, with the signed-in user.
    class Middleware < Fixwire::Rack::Middleware
      def initialize(app)
        super(app, mechanism: "rails")
      end

      def call(env)
        hub = Hub.current
        return super unless hub.enabled?

        pii = hub.client.options.send_default_pii
        hub.with_scope do |scope|
          scope.user_provider = -> { Rails.user_from(Rails.user.call(env), pii) }
          super
        end
      end
    end

    # Exceptions Rails reports (Rails.error): a request's that Rails answers with a 500, a job's,
    # and what the app reports itself. Not those Rails doesn't: 404s and other client errors.
    class ErrorSubscriber
      def report(error, handled:, severity: nil, context: {}, source: nil)
        hub = Hub.current
        return if !hub.enabled? || hub.client.captured?(error) || client_error?(error, source)

        hub.with_scope do |scope|
          scope.set_context("rails", context.transform_keys(&:to_s).merge("source" => source)) if context.any? || source
          level = { error: :error, warning: :warning, info: :info }[severity]
          hub.capture_exception(error, mechanism: source.to_s.start_with?("application.") ? "rails" : "rails.#{source}",
                                       handled: handled, level: handled ? level : nil)
        end
      end

      private

      # A request's exception Rails answers with a 4xx (record not found, bad parameters, …): an
      # executor inside Rails's error pages reports it all the same.
      def client_error?(error, source)
        source == "application.action_dispatch" && defined?(ActionDispatch::ExceptionWrapper) &&
          ActionDispatch::ExceptionWrapper.status_code_for_exception(error.class.name) < 500
      end
    end

    # The route a request matched (/orders/:id), kept where the middleware finds it: Rails forgets
    # it once routing is over.
    module Routes
      def self.subscribe
        ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*, payload|
          request = payload[:request]
          request.env["fixwire.route"] ||= request.route_uri_pattern if request.respond_to?(:route_uri_pattern)
        rescue StandardError
          nil
        end
      end
    end

    # Active Record queries as breadcrumbs and as spans of a sampled trace (dated back by their
    # duration), without their values.
    module Queries
      def self.subscribe
        ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
          record(event)
        end
      end

      def self.record(event)
        payload = event.payload
        return if %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached]

        hub = Hub.current
        return unless hub.enabled?

        sql = payload[:sql].to_s
        duration = event.duration.to_f / 1000
        hub.add_breadcrumb(Breadcrumb.new(category: "db.query", message: sql, type: "query",
                                          data: { "name" => payload[:name], "duration_ms" => event.duration.round(3) }))
        parent = hub.span
        return unless parent&.sampled

        finished = Time.now.to_f
        adapter = payload[:connection]&.adapter_name.to_s.downcase
        system = { "postgresql" => "postgresql", "sqlite" => "sqlite", "mysql2" => "mysql", "trilogy" => "mysql" }.fetch(adapter, adapter)
        Span.start(hub, sql[0, 200], op: "db.query", kind: SpanKind::CLIENT, current: false, start_time: finished - duration,
                                     attributes: { "db.system.name" => system, "db.query.text" => sql })
            .finish(end_time: finished)
      rescue StandardError
        nil
      end
    end

    # Active Job: a job carries the trace of the code that enqueued it; performing it is a span that
    # continues that trace, in a scope of its own (the job's queue as a tag, the job as context),
    # and an exception it raises is a crash, with the job.
    module ActiveJob
      def serialize
        span = Hub.current.span
        return super unless span

        super.merge("fixwire" => { "traceparent" => span.traceparent, "tracestate" => span.tracestate,
                                   "baggage" => span.baggage }.compact)
      end

      def deserialize(job_data)
        super
        @__fixwire_trace = job_data["fixwire"]
      end

      def perform_now
        hub = Hub.current
        return super unless hub.enabled?

        trace = @__fixwire_trace.is_a?(Hash) ? @__fixwire_trace : {}
        hub.with_scope do |scope|
          scope.set_tag("queue", queue_name).set_transaction(self.class.name)
               .set_context("job", { "class" => self.class.name, "id" => job_id, "executions" => executions })
          span = hub.continue_trace(trace["traceparent"], trace["tracestate"], trace["baggage"], self.class.name,
                                    op: "queue.process", attributes: { "messaging.system" => "active_job",
                                                                       "messaging.destination.name" => queue_name,
                                                                       "messaging.message.id" => job_id })
          begin
            super
          rescue Exception => e # rubocop:disable Lint/RescueException -- reported, then raised on
            hub.capture_exception(e, mechanism: "active_job", handled: false) unless hub.client.captured?(e)
            span.set_error(e)
            raise
          ensure
            span.finish
          end
        end
      end
    end
  end
end

require_relative "rails/railtie" if defined?(Rails::Railtie)
