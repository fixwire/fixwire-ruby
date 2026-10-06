# frozen_string_literal: true

require "digest"

module Fixwire
  # Turns what the scope knows into events and queues them, with the error budget, sampling,
  # before_send and redaction applied. Never raises into the app.
  class Client
    attr_reader :options, :dsn, :sessions, :budget, :redactor, :transport

    def initialize(options)
      @options = options.apply_defaults!
      @dsn = begin
        Dsn.parse(options.dsn) unless options.blank?(options.dsn)
      rescue ArgumentError => e
        warn("#{e.message}, so the SDK is off") # always, not only with debug
        nil
      end
      @budget = Budget.new(options.error_budget)
      @sessions = Sessions.new if @dsn && options.sessions?
      @redactor = Internal::Redaction::Redactor.create(options.sensitive_keys) if options.redact
      @transport = options.transport || Transport::HTTP.new(options.timeout)
      @captured = ObjectSpace::WeakMap.new
      @worker = Worker.new(self) if @dsn
    end

    def enabled? = !@dsn.nil?

    # Whether an exception was captured already, so that a log record of it is not sent twice.
    def captured?(exception) = @captured.key?(exception)

    # Whether trace headers may go to a URL, by the trace propagation targets. The URL is compared
    # without its user info, query and fragment: a target with "://" matches the URLs it starts;
    # one starting with "/", relative URLs whose path it starts (clients here see absolute ones);
    # any other is a host, with a port if it has one, matching that host and its subdomains
    # ("example.com": api.example.com, not badexample.com); a Regexp is searched in the URL.
    def propagate_to?(url)
      targets = Array(options.trace_propagation_targets)
      return false if targets.empty?

      uri = URI.parse(url.to_s)
      compared = url.to_s.sub(/[?#].*\z/m, "")
      compared = compared.sub("#{uri.userinfo}@", "") if uri.userinfo
      host = uri.host&.downcase
      targets.any? do |target|
        case target
        when Regexp then target.match?(compared)
        when String
          if target.include?("://") then compared.start_with?(target)
          elsif target.start_with?("/") then host.nil? && compared.start_with?(target)
          else host && host_target?(target.downcase, host, uri.port)
          end
        end
      end
    rescue StandardError
      false
    end

    # @api private queues an event with what the scope knows: its id, or nil when not sent
    def capture(event, scope, span)
      return nil unless enabled?

      Fixwire.busy { prepare(event, scope, span) }
    rescue StandardError => e
      log("capturing an event failed: #{e.message}")
      nil
    end

    # @api private a segment's finished spans, sent with the next batch
    def queue_spans(spans)
      records = spans.filter_map do |span|
        Otlp.span(span.record, redactor, options.max_value_length)
      rescue StandardError => e
        log("recording a span failed: #{e.message}")
        nil
      end
      @worker.push([:spans, records]) if records.any?
    end

    # Reports a run of a scheduled job: in progress when it starts, then ok or error with the
    # returned id. Its id, or nil when it was not sent. The monitor and its config are the app's
    # own names: cut to max_value_length, not masked.
    def capture_check_in(monitor, status, id: nil, duration: nil, config: nil)
      return nil unless enabled? && !monitor.to_s.strip.empty?

      id ||= Ids.generate(16)
      body = { "sdk" => Fixwire.sdk, "check_in_id" => id, "status" => status.to_s, "environment" => options.environment }
      body["duration"] = duration if duration.to_f.positive?
      body["monitor_config"] = config.to_wire if config
      body = Otlp.cut(Otlp.plain(body), options.max_value_length)
      monitor = Otlp.cut(Otlp.utf8(monitor.to_s), options.max_value_length)
      @worker.push([:request, "/v1/check-ins/#{URI.encode_uri_component(monitor)}", "check_in", body]) ? id : nil
    rescue StandardError => e
      log("sending a check-in failed: #{e.message}")
      nil
    end

    # Queues what someone said about an error or an AI answer: its id, or nil when it holds
    # neither a message nor a score.
    def capture_feedback(feedback, scope, span)
      message = feedback[:message].to_s.strip
      score = feedback[:score].to_f.finite? ? feedback[:score].to_f.clamp(-1.0, 1.0) : 0.0
      return nil if !enabled? || (message.empty? && score.zero?)

      user = scope.user
      body = { "message" => message, "name" => feedback[:name] || user&.username, "email" => feedback[:email] || user&.email,
               "url" => feedback[:url], "source" => feedback[:source] || "api", "trace_id" => feedback[:trace_id] || span&.trace_id,
               "event_id" => feedback[:event_id] }.reject { |_, v| v.nil? || v == "" }
      body["score"] = score unless score.zero?
      body = Otlp.clean(body, redactor, options.max_value_length)
      id = Ids.generate(16)
      body.merge!(Otlp.cut({ "sdk" => Fixwire.sdk, "feedback_id" => id, "timestamp" => Time.now.to_f,
                             "environment" => options.environment, "release" => options.release }.compact, options.max_value_length))
      @worker.push([:request, "/v1/feedback", "feedback", body]) ? id : nil
    rescue StandardError => e
      log("capturing feedback failed: #{e.message}")
      nil
    end

    # Sends what was captured, waiting at most timeout seconds; false when something was left.
    def flush(timeout = 2.0)
      @worker.nil? || @worker.flush(timeout)
    rescue StandardError => e
      log("flushing failed: #{e.message}")
      false
    end

    # @api private in a forked child: a worker of its own at once
    def forked
      @worker&.restart
    rescue StandardError => e
      log("restarting after a fork failed: #{e.message}")
    end

    def log(message)
      warn("fixwire: #{message}") if options&.debug
    end

    private

    def prepare(event, scope, span)
      scope.apply_to(event, span)
      # The session counts the error whether or not it is sent.
      if event.exceptions.any?
        scope.session&.mark(!event.exceptions.first.handled)
      elsif %i[error fatal].include?(event.level)
        scope.session&.mark(false)
      end
      @captured[event.exception] = true if event.exception
      held = budget.allow(Budget.issue_of(event))
      return log("dropped an event: over the error budget") if held.nil?
      return nil if options.sample_rate < 1 && rand >= options.sample_rate

      event.suppressed = held
      event.event_id ||= Ids.generate(16)
      event.timestamp ||= Time.now.to_f
      event.level ||= event.exceptions.empty? ? :info : :error
      personal_data(event)
      event = before_send(event)
      return nil if event.nil?

      @worker.push([:log, Otlp.event_record(event, redactor, options.max_value_length)]) ? event.event_id : nil
    end

    # Whether a host matches a target host, with the target's port if it has one.
    def host_target?(target, host, port)
      name, colon, wanted = target.rpartition(":")
      if colon.empty? || !wanted.match?(/\A[0-9]+\z/) # "[::1]" holds colons, not a port
        name = target
        wanted = nil
      end
      return false if name.empty? || (wanted && wanted.to_i != port)

      host == name || host.end_with?(".#{name}")
    end

    def personal_data(event)
      if options.send_default_pii
        if event.request&.client_address
          event.user ||= User.new
          event.user.ip_address ||= event.request.client_address
        end
      else
        event.user.ip_address = nil if event.user
        if event.request
          event.request = event.request.dup # the scope's stays whole
          event.request.headers = (event.request.headers || {}).reject { |name, _| Request.sensitive_header?(name) }
        end
      end
    end

    def before_send(event)
      return event if options.before_send.nil?

      changed = options.before_send.call(event)
      return nil if changed.nil?

      changed.is_a?(Event) ? changed : (log("before_send returned #{changed.class}, not an event: dropped") && nil)
    rescue StandardError => e
      log("before_send failed, sending the event as it is: #{e.message}")
      event
    end
  end
end
