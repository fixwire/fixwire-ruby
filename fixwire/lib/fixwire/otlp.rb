# frozen_string_literal: true

require "json"

module Fixwire
  # @api private builds what the protocol sends: OTLP/HTTP JSON log records (errors and messages)
  # and spans, with Fixwire's attributes. Everything but ids goes through redaction, then every
  # string is cut to max_value_length (limit) bytes. The SDK's own identity (the resource: service,
  # release, environment, host) comes from options and is only cut: masking a release would split
  # its health.
  module Otlp
    # Values are walked at most MAX_DEPTH levels deep and MAX_BREADTH items wide, MAX_OBJECTS
    # containers each.
    MAX_DEPTH = 10
    MAX_BREADTH = 100
    MAX_OBJECTS = 10_000

    module_function

    def resource(options)
      identity = plain_map(
        "service.name" => options.service_name,
        "service.version" => options.release,
        "deployment.environment.name" => options.environment,
        "host.name" => options.server_name,
        "telemetry.sdk.name" => SDK_NAME,
        "telemetry.sdk.version" => VERSION,
        "telemetry.sdk.language" => "ruby"
      )
      { "attributes" => attributes(cut(identity, options.max_value_length)) }
    end

    def scope = { "name" => SDK_NAME, "version" => VERSION }

    # The request bodies, around records already in JSON (each was encoded once, to weigh it).
    def logs(options, records) = request("resourceLogs", "scopeLogs", "logRecords", options, records)
    def traces(options, spans) = request("resourceSpans", "scopeSpans", "spans", options, spans)

    def request(resources, scopes, list, options, records)
      %({"#{resources}":[{"resource":#{JSON.generate(resource(options))},"#{scopes}":[{"scope":#{JSON.generate(scope)},) +
        %("#{list}":[#{records.join(",")}]}]}]})
    end

    # A span's record: at most Span::MAX_ATTRIBUTES attributes, its operation among them.
    def span(record, redactor, limit)
      attrs = record["attributes"].dup
      op = attrs.delete("fixwire.op")
      attrs = attrs.first(Span::MAX_ATTRIBUTES - 1).to_h
      attrs["fixwire.op"] = op
      status = record["status"]
      status = status.merge("message" => mask(status["message"], redactor, limit)) if status["message"]
      record.merge("attributes" => attributes(clean(attrs, redactor, limit)), "name" => mask(record["name"], redactor, limit),
                   "status" => status)
    end

    def event_record(event, redactor, limit)
      a = { "fixwire.tags" => event.tags, "fixwire.transaction" => event.transaction, "fixwire.fingerprint" => event.fingerprint }
      a["fixwire.suppressed"] = event.suppressed if event.suppressed.to_i.positive?
      if (user = event.user)
        a.merge!("user.id" => user.id, "user.email" => user.email, "user.name" => user.username,
                 "client.address" => user.ip_address)
      end
      a["fixwire.contexts"] = event.contexts
      event.extra.first(MAX_BREADTH).each { |k, v| a[k.to_s] ||= v }
      # The SDK's own lists, as long as their options say: each item is a value of its own (their
      # places in a are kept for them).
      own = {}
      if event.breadcrumbs.any?
        a["fixwire.breadcrumbs"] = nil
        own["fixwire.breadcrumbs"] = event.breadcrumbs.map do |b|
          plain({ "timestamp" => b.timestamp, "type" => b.type, "category" => b.category, "message" => b.message,
                  "level" => b.level, "data" => b.data })
        end
      end
      if (r = event.request)
        a.merge!("http.request.method" => r.http_method, "url.full" => r.url, "url.query" => r.query, "http.route" => r.current_route)
        (r.headers || {}).first(MAX_BREADTH).each do |name, value|
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
        record["body"] = value(mask(event.message, redactor, limit))
      else
        record["eventName"] = "exception"
        a["exception.type"] = event.exceptions.first.type
        a["exception.message"] = event.exceptions.first.message
        a["fixwire.exceptions"] = nil
        own["fixwire.exceptions"] = event.exceptions.map { |x| exception(x) }
        a["fixwire.handled"] = false unless event.exceptions.all?(&:handled)
        record["body"] = value(mask(event.message, redactor, limit)) unless event.message.to_s.empty?
      end
      clean = clean(plain_map(a).merge(own), redactor, limit, plain: false)
      clean["fixwire.event_id"] = event.event_id
      record["attributes"] = attributes(clean)
      record
    end

    # An exception and its frames, each frame a value of its own (there are max_stack_frames).
    def exception(value)
      frames = value.frames.map do |f|
        frame = { "function" => f.function, "module" => f.module, "file" => f.file }
        frame["line"] = f.line if f.line.to_i.positive?
        frame["in_app"] = f.in_app
        frame.merge!("context_line" => f.context_line, "pre_context" => f.pre_context, "post_context" => f.post_context) if f.context_line
        plain(frame)
      end
      plain({ "type" => value.type, "message" => value.message, "module" => value.module,
              "mechanism" => { "type" => value.mechanism, "handled" => value.handled } }).merge("frames" => frames)
    end

    # A map as sent: plain values (unless they are already), every string and key masked, then
    # cut to limit bytes.
    def clean(map, redactor, limit, plain: true)
      map = plain_map(map) if plain
      return cut(map, limit) if redactor.nil?

      walked, = redactor.walk(map, limit: limit)
      walked.is_a?(Hash) ? walked : {}
    end

    # A string as sent: masked, then cut to limit bytes.
    def mask(text, redactor, limit)
      return cut(utf8(text.to_s), limit) if redactor.nil?

      redactor.mask(text.to_s, limit: limit).first
    end

    # Every string (and key) of a plain value in at most limit bytes.
    def cut(value, limit)
      case value
      when String then Internal::Redaction::Text.cut(value, limit)
      when Array then value.map { |v| cut(v, limit) }
      when Hash then value.to_h { |k, v| [cut(k, limit), cut(v, limit)] }
      else value
      end
    end

    def plain_map(map) = map.to_h { |k, v| [utf8(k.to_s), plain(v)] }

    # JSON-like values only: strings in UTF-8, symbols and other objects as text, NaN and the
    # infinities as "NaN", "Infinity" and "-Infinity". A container holding itself (a tree whose
    # nodes know their parent) is "[Circular ~]" where it comes round again; one deeper than
    # MAX_DEPTH, or past MAX_OBJECTS, is "[Object]" or "[Array]"; past MAX_BREADTH items, the rest
    # are left out. A value that can't be read (its to_s raises) is "[Unreadable]".
    def plain(value, depth = 1, walk = nil)
      case value
      when nil, true, false, Integer then value
      when Float then value.finite? ? value : value.to_s
      when String then utf8(value)
      when Symbol then utf8(value.name)
      when Time then value.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      when Hash, Array, Struct
        walk ||= { seen: {}.compare_by_identity, objects: 0 }
        return "[Circular ~]" if walk[:seen].key?(value)
        return value.is_a?(Array) ? "[Array]" : "[Object]" if depth > MAX_DEPTH || (walk[:objects] += 1) > MAX_OBJECTS

        walk[:seen][value] = true
        begin
          if value.is_a?(Array)
            value.first(MAX_BREADTH).map { |v| plain(v, depth + 1, walk) }
          else
            (value.is_a?(Hash) ? value : value.to_h).first(MAX_BREADTH).to_h { |k, v| [utf8(k.to_s), plain(v, depth + 1, walk)] }
          end
        ensure
          walk[:seen].delete(value)
        end
      else
        utf8(value.to_s)
      end
    rescue StandardError
      "[Unreadable]"
    end

    def utf8(text) = Internal::Redaction::Text.utf8(text)

    # OTLP key-values, without empty ones.
    def attributes(map)
      map.filter_map do |k, v|
        next if v.nil? || v == "" || v == [] || v == {}

        { "key" => k.to_s, "value" => value(v) }
      end
    end

    # A plain value as OTLP's AnyValue.
    def value(value)
      case value
      when nil then { "stringValue" => "" }
      when String then { "stringValue" => value }
      when true, false then { "boolValue" => value }
      when Integer then { "intValue" => value.to_s }
      when Float then value.finite? ? { "doubleValue" => value } : { "stringValue" => value.to_s }
      when Array then { "arrayValue" => { "values" => value.map { |v| value(v) } } }
      when Hash then { "kvlistValue" => { "values" => attributes(value) } }
      else { "stringValue" => value.to_s }
      end
    end
  end
end
