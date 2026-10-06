# frozen_string_literal: true

module Fixwire
  # What is known about the work under way (the user, tags, contexts, breadcrumbs, the request),
  # added to every event captured with it.
  class Scope
    attr_reader :tags, :contexts, :extra, :breadcrumbs, :fingerprint
    attr_accessor :level, :transaction, :request
    # The user when none was set, read when an event needs it (frameworks know the signed-in user
    # only once their authentication ran).
    attr_accessor :user_provider
    # @api private the session of the request the scope serves
    attr_accessor :session

    def initialize
      clear
    end

    def initialize_copy(source)
      super
      @tags = source.tags.dup
      @contexts = source.contexts.dup
      @extra = source.extra.dup
      @breadcrumbs = source.breadcrumbs.dup
      @fingerprint = source.fingerprint.dup
      @user = source.instance_variable_get(:@user)&.dup
    end

    def user
      return @user.dup if @user
      return nil unless user_provider

      User.from(user_provider.call)
    rescue StandardError
      nil
    end

    # A User, a Hash (id:, email:, username:) or an id; nil removes it.
    def user=(user)
      @user = User.from(user)
    end

    def set_user(user) = tap { self.user = user }

    # A searchable tag; nil removes it.
    def set_tag(key, value)
      value.nil? ? @tags.delete(key.to_s) : @tags[key.to_s] = value.to_s
      self
    end

    # A named group of details, such as an order's id and items; nil removes it.
    def set_context(name, values)
      values.nil? ? @contexts.delete(name.to_s) : @contexts[name.to_s] = values
      self
    end

    # A detail sent with events; nil removes it.
    def set_extra(key, value)
      value.nil? ? @extra.delete(key.to_s) : @extra[key.to_s] = value
      self
    end

    def set_level(level) = tap { self.level = Fixwire.level(level) }
    def set_transaction(name) = tap { self.transaction = name }

    # Groups the events captured with the scope; "{{ default }}" stands for Fixwire's own grouping.
    def set_fingerprint(*parts) = tap { @fingerprint = parts.flatten.map(&:to_s) }

    # Records something that happened; past max, the oldest go.
    def add_breadcrumb(breadcrumb, max = 100)
      return self if max <= 0

      breadcrumb.timestamp ||= Process.clock_gettime(Process::CLOCK_REALTIME)
      @breadcrumbs << breadcrumb
      @breadcrumbs.shift(@breadcrumbs.size - max) if @breadcrumbs.size > max
      self
    end

    def clear_breadcrumbs = tap { @breadcrumbs = [] }

    # Forgets everything (workers, between jobs).
    def clear
      @user = nil
      @tags = {}
      @contexts = {}
      @extra = {}
      @breadcrumbs = []
      @fingerprint = []
      @level = @transaction = @request = @user_provider = @session = nil
      self
    end

    # @api private adds what the scope knows to an event; the event's own details win
    def apply_to(event, span)
      event.user ||= user
      event.tags = tags.merge(event.tags)
      event.contexts = contexts.merge(event.contexts)
      event.extra = extra.merge(event.extra)
      event.breadcrumbs = breadcrumbs.dup if event.breadcrumbs.empty?
      event.level ||= level
      event.fingerprint = fingerprint.dup if event.fingerprint.empty?
      event.request ||= request
      event.transaction ||= transaction
      route = event.request&.current_route
      event.transaction ||= [event.request.http_method, route].compact.join(" ") if route
      event.transaction ||= span&.segment_name
      return unless event.trace_id.nil? && span

      event.trace_id = span.trace_id
      event.span_id = span.span_id
    end
  end
end
