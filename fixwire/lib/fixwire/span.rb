# frozen_string_literal: true

require "securerandom"

module Fixwire
  # OpenTelemetry's span kinds.
  module SpanKind
    INTERNAL = 1
    SERVER = 2
    CLIENT = 3
    PRODUCER = 4
    CONSUMER = 5

    # The kind an operation implies.
    def self.of(op)
      case op.to_s
      when "http.server", /\.server\z/ then SERVER
      when "http.client", /\Adb/, /\.client\z/ then CLIENT
      when /\.publish\z/ then PRODUCER
      when /\.process\z/ then CONSUMER
      else INTERNAL
      end
    end
  end

  # A timed operation of a trace. A span without a parent in the process is a segment: it is sent
  # with the spans finished under it when it finishes.
  class Span
    MAX_CHILDREN = 1000
    # W3C's limits for a caller's tracestate and baggage: longer ones are not passed on.
    MAX_TRACESTATE = 512
    MAX_BAGGAGE = 8192

    attr_reader :trace_id, :span_id, :parent_span_id, :sampled, :tracestate, :baggage, :kind, :op, :start_time,
                :end_time, :attributes
    attr_accessor :name

    # @api private use Fixwire.start_span, Fixwire.trace or Hub#start_span
    def self.start(hub, name, op: nil, attributes: {}, kind: nil, traceparent: nil, tracestate: nil, baggage: nil,
                   current: true, start_time: nil)
      parent = traceparent.nil? ? hub.span : nil
      span = new(hub, name, op, attributes, kind, parent, traceparent, tracestate, baggage, start_time)
      if current
        span.instance_variable_set(:@previous, hub.span)
        hub.span = span
      end
      span
    end

    def initialize(hub, name, op, attributes, kind, parent, traceparent, tracestate, baggage, start_time)
      @hub = hub
      @name = name.to_s
      @op = op
      @attributes = attributes.to_h.transform_keys(&:to_s)
      @span_id = Ids.generate(8)
      @start_time = start_time || Time.now.to_f
      @children = []
      @failed = false
      @remote_parent = false
      continued = traceparent && Span.parse_traceparent(traceparent)
      if continued
        @trace_id, @parent_span_id, @sampled = continued
        @remote_parent = true
        @tracestate = tracestate if tracestate.to_s.bytesize <= MAX_TRACESTATE
        @baggage = baggage if baggage.to_s.bytesize <= MAX_BAGGAGE
        @segment = self
      elsif parent
        @trace_id = parent.trace_id
        @parent_span_id = parent.span_id
        @sampled = parent.sampled
        @tracestate = parent.tracestate
        @baggage = parent.baggage
        @segment = parent.segment
      else
        @trace_id = Ids.generate(16)
        @sampled = Span.sample(@trace_id, hub.client&.options&.traces_sample_rate || 0.0)
        @segment = self
      end
      @kind = kind || SpanKind.of(op)
    end

    # @api private
    attr_reader :segment

    def segment_name = segment.name

    def set_attribute(key, value)
      @attributes[key.to_s] = value
      self
    end

    # Marks the span failed, with the exception or a message.
    def set_error(error = nil)
      @failed = true
      @status_message = error.is_a?(Exception) ? error.message : error&.to_s
      self
    end

    def failed? = @failed
    def finished? = !@end_time.nil?

    # The W3C traceparent header that continues this span's trace.
    def traceparent
      "00-#{trace_id}-#{span_id}-#{sampled ? "01" : "00"}"
    end

    # Finishes the span and makes the span before it current again. end_time dates work timed
    # elsewhere (a query that ran already).
    def finish(end_time: nil)
      return if @end_time

      @end_time = end_time || Time.now.to_f
      @hub.span = @previous if @hub.span.equal?(self)
      client = @hub.client
      return unless sampled && client&.enabled?

      if segment.equal?(self)
        spans = @children + [self]
        @children = []
        @sent = true
        client.queue_spans(spans)
      elsif segment.sent?
        client.queue_spans([self])
      elsif segment.children.size < MAX_CHILDREN
        segment.children << self
      end
    end

    # @api private
    def sent? = @sent == true
    # @api private
    attr_reader :children

    # @api private the span as the protocol sends it, attributes still plain
    def record
      record = { "traceId" => trace_id, "spanId" => span_id }
      record["parentSpanId"] = parent_span_id if parent_span_id
      status = { "code" => @failed ? 2 : 1 }
      status["message"] = @status_message if @failed && @status_message
      record.merge(
        "name" => name,
        "kind" => kind,
        "startTimeUnixNano" => Span.nanos(start_time),
        "endTimeUnixNano" => Span.nanos(end_time || Time.now.to_f),
        "attributes" => attributes.merge("fixwire.op" => op),
        "status" => status,
        "flags" => 0x100 | (@remote_parent ? 0x200 : 0) | (sampled ? 1 : 0)
      )
    end

    # Unix seconds as the decimal nanoseconds OTLP JSON takes.
    def self.nanos(seconds)
      whole = seconds.floor
      micros = [((seconds - whole) * 1_000_000).round, 999_999].min
      format("%<whole>d%<micros>06d000", whole: whole, micros: micros)
    end

    # The shared sampling rule: a trace is kept when the last 56 bits of its id, as a share of 2^56,
    # are at least 1 - rate; every service decides the same for the same trace.
    def self.sample(trace_id, rate)
      return false if rate <= 0
      return true if rate >= 1

      tail = trace_id.to_s[-14..]
      return false unless tail&.match?(/\A\h{14}\z/)

      tail.to_i(16) / (2**56).to_f >= 1 - rate
    end

    # [trace_id, parent_span_id, sampled] from a W3C traceparent, or nil when it is malformed.
    def self.parse_traceparent(header)
      parts = header.to_s.strip.split("-")
      return nil if parts.size < 4 || parts[0].size != 2 || parts[0].casecmp?("ff")
      return nil unless parts[1].size == 32 && parts[2].size == 16 && parts[3].size == 2
      return nil unless parts[0..3].join.match?(/\A\h+\z/)
      return nil if parts[1].delete("0").empty? || parts[2].delete("0").empty?

      [parts[1].downcase, parts[2].downcase, parts[3].to_i(16).odd?]
    end
  end

  # @api private random ids, as lower-case hex
  module Ids
    def self.generate(bytes)
      loop do
        id = SecureRandom.hex(bytes)
        return id unless id.delete("0").empty?
      end
    end
  end
end
