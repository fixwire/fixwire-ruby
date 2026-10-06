# frozen_string_literal: true

require "json"

module Fixwire
  # @api private builds what the protocol sends: OTLP/HTTP JSON log records (errors and messages)
  # and spans, with Fixwire's attributes. Everything but ids goes through redaction.
  module Otlp
    MAX_DEPTH = 10

    module_function

    def resource(options)
      { "attributes" => attributes(
        "service.name" => options.service_name,
        "service.version" => options.release,
        "deployment.environment.name" => options.environment,
        "host.name" => options.server_name,
        "telemetry.sdk.name" => SDK_NAME,
        "telemetry.sdk.version" => VERSION,
        "telemetry.sdk.language" => "ruby"
      ) }
    end

    def scope = { "name" => SDK_NAME, "version" => VERSION }

    # The request bodies, around records already in JSON (each was encoded once, to weigh it).
    def logs(options, records) = request("resourceLogs", "scopeLogs", "logRecords", options, records)
    def traces(options, spans) = request("resourceSpans", "scopeSpans", "spans", options, spans)

    def request(resources, scopes, list, options, records)
      %({"#{resources}":[{"resource":#{JSON.generate(resource(options))},"#{scopes}":[{"scope":#{JSON.generate(scope)},) +
        %("#{list}":[#{records.join(",")}]}]}]})
    end

    def span(record, redactor)
      attrs = record["attributes"].dup
      op = attrs.delete("fixwire.op")
      plain = scrub(plain_map(attrs), redactor)
      plain["fixwire.op"] = op
      status = record["status"]
      status = status.merge("message" => mask(status["message"], redactor)) if status["message"]
      record.merge("attributes" => attributes(plain), "name" => mask(record["name"].to_s, redactor), "status" => status)
    end

    def event_record(event, redactor)
      a = { "fixwire.tags" => event.tags, "fixwire.transaction" => event.transaction, "fixwire.fingerprint" => event.fingerprint }
      a["fixwire.suppressed"] = event.suppressed if event.suppressed.to_i.positive?
      if (user = event.user)
        a.merge!("user.id" => user.id, "user.email" => user.email, "user.name" => user.username,
                 "client.address" => user.ip_address)
      end
      a["fixwire.contexts"] = event.contexts
      event.extra.each { |k, v| a[k.to_s] ||= v }
      if event.breadcrumbs.any?
        a["fixwire.breadcrumbs"] = event.breadcrumbs.map do |b|
          { "timestamp" => b.timestamp, "type" => b.type, "category" => b.category, "message" => b.message,
            "level" => b.level&.to_s, "data" => b.data }
        end
      end
      if (r = event.request)
        a.merge!("http.request.method" => r.http_method, "url.full" => r.url, "url.query" => r.query, "http.route" => r.current_route)
        (r.headers || {}).each do |name, value|
          name = name.to_s.downcase
          a[name == "user-agent" ? "user_agent.original" : "http.request.header.#{name}"] = value
        end
      end
      level = event.level || :error
      record = { "timeUnixNano" => Span.nanos(event.timestamp || Time.now.to_f), "severityNumber" => LEVELS.fetch(level),
                 "severityText" => level.to_s.upcase }
      record.merge!("traceId" => event.trace_id, "spanId" => event.span_id) if event.trace_id
      if event.exceptions.empty?
        record["eventName"] = "fixwire.message"
        record["body"] = value(mask(event.message.to_s, redactor))
      else
        record["eventName"] = "exception"
        a["exception.type"] = event.exceptions.first.type
        a["exception.message"] = event.exceptions.first.message
        a["fixwire.exceptions"] = event.exceptions.map { |x| exception(x) }
        a["fixwire.handled"] = false unless event.exceptions.all?(&:handled)
        record["body"] = value(mask(event.message, redactor)) unless event.message.to_s.empty?
      end
      plain = scrub(plain_map(a), redactor)
      plain["fixwire.event_id"] = event.event_id
      record["attributes"] = attributes(plain)
      record
    end

    def exception(value)
      frames = value.frames.map do |f|
        frame = { "function" => f.function, "module" => f.module, "file" => f.file }
        frame["line"] = f.line if f.line.to_i.positive?
        frame["in_app"] = f.in_app
        frame.merge!("context_line" => f.context_line, "pre_context" => f.pre_context, "post_context" => f.post_context) if f.context_line
        frame
      end
      { "type" => value.type, "message" => value.message, "module" => value.module,
        "mechanism" => { "type" => value.mechanism, "handled" => value.handled }, "frames" => frames }
    end

    def scrub(map, redactor)
      return map if redactor.nil?

      walked, = redactor.walk(map)
      walked.is_a?(Hash) ? walked : {}
    end

    def mask(text, redactor)
      return utf8(text.to_s) if redactor.nil? || text.to_s.empty?

      redactor.mask(text.to_s).first
    end

    def plain_map(map) = map.to_h { |k, v| [utf8(k.to_s), plain(v, 1)] }

    # JSON-like values only: strings in UTF-8, symbols and other objects as text. A container
    # holding itself (a tree whose nodes know their parent) is cut where it comes round again.
    def plain(value, depth, seen = nil)
      case value
      when nil, true, false, Integer then value
      when Float then value.finite? ? value : value.to_s
      when String then utf8(value)
      when Symbol then value.to_s
      when Time then value.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      when Hash, Array, Struct
        return "[too deep]" if depth > MAX_DEPTH

        seen ||= {}.compare_by_identity
        return "[Circular ~]" if seen.key?(value)

        seen[value] = true
        begin
          if value.is_a?(Array)
            value.map { |v| plain(v, depth + 1, seen) }
          else
            value.to_h.to_h { |k, v| [utf8(k.to_s), plain(v, depth + 1, seen)] }
          end
        ensure
          seen.delete(value)
        end
      else
        utf8(value.to_s)
      end
    rescue StandardError
      value.class.to_s
    end

    def utf8(text) = Internal::Redaction::Text.utf8(text)

    # OTLP key-values, without empty ones.
    def attributes(map)
      map.filter_map do |k, v|
        next if v.nil? || v == "" || v == [] || v == {}

        { "key" => k.to_s, "value" => value(v) }
      end
    end

    def value(value)
      value = plain(value, 1)
      case value
      when nil then { "stringValue" => "" }
      when String then { "stringValue" => value }
      when true, false then { "boolValue" => value }
      when Integer then { "intValue" => value.to_s }
      when Float then { "doubleValue" => value }
      when Array then { "arrayValue" => { "values" => value.map { |v| value(v) } } }
      when Hash then { "kvlistValue" => { "values" => attributes(value) } }
      else { "stringValue" => value.to_s }
      end
    end
  end
end
