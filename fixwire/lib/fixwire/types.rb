# frozen_string_literal: true

module Fixwire
  # Levels, from least to most severe, with OpenTelemetry's severity numbers.
  LEVELS = { debug: 5, info: 9, warning: 13, error: 17, fatal: 21 }.freeze

  def self.level(value)
    level = value.respond_to?(:to_sym) ? value.to_sym : nil
    level = :warning if level == :warn
    LEVELS.key?(level) ? level : nil
  rescue StandardError
    nil
  end

  # The user an event or a session belongs to. ip_address is sent only with send_default_pii.
  User = Struct.new(:id, :email, :username, :ip_address, keyword_init: true) do
    def self.from(value)
      case value
      when nil, User then value
      when Hash then new(**value.transform_keys(&:to_sym).slice(:id, :email, :username, :ip_address))
      else new(id: value.to_s)
      end
    end

    def empty?
      [id, email, username].all? { |v| v.nil? || v.to_s.empty? }
    end
  end

  # Something that happened before an event: a log line, a query, a call to another service.
  Breadcrumb = Struct.new(:category, :message, :level, :type, :data, :timestamp, keyword_init: true)

  # The HTTP request an event happened in. route_provider reads the route when an event needs it
  # (frameworks match it after the request started).
  Request = Struct.new(:http_method, :url, :query, :headers, :route, :client_address, :route_provider, keyword_init: true) do
    def self.sensitive_header?(name)
      Request::SENSITIVE_HEADERS.include?(name.to_s.downcase)
    end

    def current_route
      return route if route || route_provider.nil?

      route_provider.call
    rescue StandardError
      nil
    end
  end

  # Headers sent only with send_default_pii: they may identify someone or hold a secret (proxies
  # and CDNs pass the user's IP address in several).
  Request::SENSITIVE_HEADERS = %w[authorization proxy-authorization cookie set-cookie x-forwarded-for x-real-ip forwarded
                                  cf-connecting-ip true-client-ip x-client-ip x-api-key].freeze

  # One call in a stack trace.
  Frame = Struct.new(:function, :module, :file, :line, :in_app, :context_line, :pre_context, :post_context, keyword_init: true)

  # One exception of a chain, outermost first.
  ExceptionValue = Struct.new(:type, :message, :module, :mechanism, :handled, :frames, keyword_init: true)

  # What is sent for an error or a message; the scope fills in what it knows.
  class Event
    attr_accessor :event_id, :timestamp, :level, :message, :exceptions, :exception, :tags, :contexts, :extra,
                  :user, :breadcrumbs, :fingerprint, :transaction, :request, :trace_id, :span_id, :suppressed

    def initialize(message: nil, level: nil)
      @message = message
      @level = level
      @exceptions = []
      @tags = {}
      @contexts = {}
      @extra = {}
      @breadcrumbs = []
      @fingerprint = []
      @suppressed = 0
    end
  end

  # How a scheduled job runs, for the monitor its first check-in creates or updates.
  class MonitorConfig
    attr_reader :schedule_type, :schedule, :unit, :checkin_margin, :max_runtime, :timezone

    def self.crontab(expression, checkin_margin: 0, max_runtime: 0, timezone: nil)
      new("crontab", expression, nil, checkin_margin, max_runtime, timezone)
    end

    # A job that runs every so many units: minute, hour, day, week, month or year.
    def self.interval(every, unit, checkin_margin: 0, max_runtime: 0, timezone: nil)
      new("interval", every, unit, checkin_margin, max_runtime, timezone)
    end

    def initialize(type, schedule, unit, checkin_margin, max_runtime, timezone)
      @schedule_type = type
      @schedule = schedule
      @unit = unit
      @checkin_margin = checkin_margin
      @max_runtime = max_runtime
      @timezone = timezone
    end

    def to_wire
      schedule = { "type" => schedule_type, "value" => self.schedule }
      schedule["unit"] = unit if unit
      wire = { "schedule" => schedule }
      wire["checkin_margin"] = checkin_margin if checkin_margin.to_i.positive?
      wire["max_runtime"] = max_runtime if max_runtime.to_i.positive?
      wire["timezone"] = timezone if timezone
      wire
    end
  end
end
