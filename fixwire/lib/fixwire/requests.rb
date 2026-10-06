# frozen_string_literal: true

module Fixwire
  # An incoming HTTP request, for server integrations: a server span that continues the caller's
  # trace, the request's details on the events captured while it runs, and its session.
  class ServerRequest
    attr_reader :span, :request

    # Starts tracking a request on the hub's current scope. headers: lower-case names.
    def self.start(hub, method, url, headers, client_address: nil)
      method = method.to_s.upcase
      headers = headers.to_h.transform_keys { |k| k.to_s.downcase }
      uri = URI.parse(url.to_s)
      path = uri.path.to_s.empty? ? "/" : uri.path
      request = Request.new(http_method: method, url: url.to_s.sub(/[?#].*\z/m, ""), query: uri.query, headers: headers,
                            client_address: client_address)
      hub.scope.request = request
      span = hub.continue_trace(headers["traceparent"], headers["tracestate"], headers["baggage"], "#{method} #{path}",
                                op: "http.server",
                                attributes: { "http.request.method" => method, "url.path" => path, "url.scheme" => uri.scheme,
                                              "server.address" => uri.host, "user_agent.original" => headers["user-agent"] })
      new(hub, span, request, hub.start_request_session)
    rescue URI::InvalidURIError
      start(hub, method, "http://unknown/", headers, client_address: client_address)
    end

    def initialize(hub, span, request, end_session)
      @hub = hub
      @span = span
      @request = request
      @end_session = end_session
      @ended = false
    end

    # Names the route the request matched, such as /orders/:id: the span's name and the events'
    # transaction.
    def route = request.route

    def route=(route)
      return if route.nil? || route.to_s.empty?

      request.route = route.to_s
      span.name = "#{request.http_method} #{route}"
      span.set_attribute("http.route", route.to_s)
    end

    # Ends the request with its status code; a 5xx fails the span. Later calls do nothing.
    def finish(status)
      return if @ended

      @ended = true
      span.set_attribute("http.response.status_code", status.to_i)
      span.set_error("HTTP #{status}") if status.to_i >= 500
      span.finish
      @end_session.call
    rescue StandardError => e
      @hub.client&.log("ending a request failed: #{e.message}")
    end
  end

  # An outgoing HTTP request, for HTTP client integrations: a client span under the current span
  # when it is sampled, trace headers when the URL is one of the trace propagation targets, and an
  # http breadcrumb when it ends. Nothing here raises into the caller's request.
  class OutgoingRequest
    # Starts tracking a request; the block adds a trace header to it before it is sent.
    def self.start(hub, method, url, &set_header)
      plain = url.to_s.sub(/[?#].*\z/m, "")
      method = method.to_s.upcase
      parent = hub.span
      span = nil
      if parent&.sampled
        host = URI.parse(url.to_s).host rescue nil # rubocop:disable Style/RescueModifier
        span = Span.start(hub, "#{method} #{plain}", op: "http.client", kind: SpanKind::CLIENT, current: false,
                                                     attributes: { "http.request.method" => method, "url.full" => plain, "server.address" => host })
      end
      from = span || parent
      if from && hub.client&.propagate_to?(url) && set_header
        set_header.call("traceparent", from.traceparent)
        set_header.call("tracestate", from.tracestate) if from.tracestate
        set_header.call("baggage", from.baggage) if from.baggage
      end
      new(hub, method, plain, span)
    rescue StandardError
      new(hub, method, plain, nil) # tracing never breaks the request
    end

    def initialize(hub, method, url, span)
      @hub = hub
      @method = method
      @url = url
      @span = span
      @ended = false
    end

    # Ends the request with the server's answer; a 4xx or 5xx fails the span.
    def finish(status) = done(status.to_i, nil)

    # Ends a request that got no answer.
    def fail(error) = done(0, error)

    private

    def done(status, error)
      return if @ended

      @ended = true
      if @span
        @span.set_attribute("http.response.status_code", status) if status.positive?
        if error
          @span.set_error(error)
        elsif status >= 400
          @span.set_error("HTTP #{status}")
        end
        @span.finish
      end
      data = { "method" => @method, "url" => @url }
      data["status_code"] = status if status.positive?
      @hub.add_breadcrumb(Breadcrumb.new(category: "http", type: "http", data: data,
                                         level: error || status >= 500 ? :error : :info))
    rescue StandardError
      nil
    end
  end
end
