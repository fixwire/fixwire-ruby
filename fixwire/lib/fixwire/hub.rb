# frozen_string_literal: true

module Fixwire
  # Pairs the client with a stack of scopes and the current span. The current hub lives in fiber
  # storage: a thread or fiber started from another inherits it, and from its first use works on
  # a copy of its own, so concurrent requests and jobs don't see each other's scopes.
  class Hub
    STORAGE = :__fixwire_hub

    attr_reader :client
    attr_accessor :span

    class << self
      attr_accessor :main

      def current
        hub = Fiber[STORAGE]
        if hub.nil?
          hub = (self.main ||= new(nil)).clone_for_fiber
        elsif !hub.owned_by?(Fiber.current)
          hub = hub.clone_for_fiber # inherited from the fiber or thread that started this one
        elsif hub.client || main&.client.nil?
          return hub
        end
        hub.bind_client(main.client) if hub.client.nil? && main&.client # a thread started before init
        Fiber[STORAGE] = hub
      end

      # Makes a hub the current one (tests, runtimes that serve several apps).
      def current=(hub)
        Fiber[STORAGE] = hub
        hub&.adopt
      end
    end

    def initialize(client, scope = Scope.new)
      @client = client
      @scopes = [scope]
      @span = nil
      @owner = Fiber.current
    end

    def owned_by?(fiber) = @owner.equal?(fiber)

    # @api private
    def adopt
      @owner = Fiber.current
    end

    # @api private a copy for another fiber: its scope as it is now, the same client and span
    def clone_for_fiber
      copy = Hub.new(client, scope.dup)
      copy.span = span
      copy
    end

    def bind_client(client)
      @client = client
    end

    def scope = @scopes.last

    # Runs a block with a copy of the current scope: what it sets there is gone afterwards.
    def with_scope
      @scopes.push(scope.dup)
      yield scope
    ensure
      @scopes.pop
    end

    # @api private for integrations whose work starts and ends in separate callbacks: a copy of the
    # current scope, current until pop_scope
    def push_scope
      @scopes.push(scope.dup)
      scope
    end

    # @api private the outermost scope stays
    def pop_scope
      @scopes.pop if @scopes.size > 1
    end

    def enabled? = client&.enabled? == true

    def capture_exception(exception, mechanism: "generic", handled: true, level: nil)
      return nil unless enabled?

      event = Event.new(level: level || (handled ? nil : :fatal))
      event.exception = exception
      event.exceptions = Frames.chain(exception, mechanism, handled, client.options)
      remember(client.capture(event, scope, span))
    rescue StandardError => e
      client&.log("reading an exception failed: #{e.message}") # never into the app
      nil
    end

    def capture_message(message, level: nil)
      return nil unless enabled?

      remember(client.capture(Event.new(message: message.to_s, level: Fixwire.level(level)), scope, span))
    rescue StandardError => e
      client&.log("reading a message failed: #{e.message}") # its to_s, say
      nil
    end

    def capture_event(event)
      return nil unless enabled?

      remember(client.capture(event, scope, span))
    end

    # Records a breadcrumb on the scope, after before_breadcrumb; what that callback logs is not
    # one more.
    def add_breadcrumb(breadcrumb)
      Fixwire.busy do
        max = 100
        options = client&.options
        if options
          max = options.max_breadcrumbs
          if options.before_breadcrumb
            breadcrumb = begin
              options.before_breadcrumb.call(breadcrumb)
            rescue StandardError => e
              client.log("before_breadcrumb failed, keeping the breadcrumb as it is: #{e.message}")
              breadcrumb
            end
            return if breadcrumb.nil?
          end
        end
        return client&.log("dropped a #{breadcrumb.class}: not a breadcrumb") unless breadcrumb.is_a?(Breadcrumb)

        scope.add_breadcrumb(breadcrumb, max)
      end
    rescue StandardError => e
      client&.log("adding a breadcrumb failed: #{e.message}")
      nil
    end

    # Starts a span under the current one (or a new trace) and makes it current until it finishes.
    def start_span(name, op: nil, attributes: {}, kind: nil)
      Span.start(self, name, op: op, attributes: attributes, kind: kind)
    end

    # Starts a span that continues a caller's trace, from its W3C headers; a malformed traceparent
    # starts a new trace. The caller's sampling decision holds.
    def continue_trace(traceparent, tracestate, baggage, name, op: nil, attributes: {})
      Span.start(self, name, op: op, attributes: attributes, traceparent: traceparent, tracestate: tracestate,
                             baggage: baggage)
    end

    # Starts the session of the request the scope serves, for release health; call the result when
    # the request ends. Integrations do this.
    def start_request_session
      sessions = client&.sessions
      return -> {} if sessions.nil?

      request_session = RequestSession.new
      started_in = scope
      started_in.session = request_session
      ended = false
      lambda do
        next if ended

        ended = true
        # The user may have been set later, on a scope of the request's own.
        user = scope.user || started_in.user
        sessions.record(request_session.status, Sessions.device_id(user), Time.now.to_f)
      end
    end

    def capture_check_in(monitor, status, id: nil, duration: nil, config: nil)
      client&.capture_check_in(monitor, status, id: id, duration: duration, config: config)
    end

    def capture_feedback(**feedback)
      return nil unless enabled?

      client.capture_feedback(feedback, scope, span)
    end

    # Sends what was captured and waits for it, at most timeout seconds; false when something was
    # left unsent.
    def flush(timeout = 2.0)
      client.nil? || client.flush(timeout)
    end

    class << self
      attr_reader :last_event_id

      # @api private
      def remember(id)
        @last_event_id = id if id
        id
      end
    end

    private

    def remember(id) = Hub.remember(id)
  end

  # @api private the session of the request a scope serves: ok, errored or crashed
  class RequestSession
    attr_reader :status

    def initialize
      @status = "ok"
    end

    def mark(crashed)
      if crashed
        @status = "crashed"
      elsif @status == "ok"
        @status = "errored"
      end
    end
  end
end
