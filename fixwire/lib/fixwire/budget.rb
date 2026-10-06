# frozen_string_literal: true

module Fixwire
  # @api private the error budget at work: a crash loop costs a few events and a count, not the
  # quota. Each issue (a cheap fingerprint; the server's grouping is the real one) may send a
  # burst, then so many a minute, within a budget for all of them; occurrences held back ride on
  # the issue's next event.
  class Budget
    MAX_ISSUES = 1024
    TOP_FRAMES = 5
    # Parts of a message that change between occurrences.
    VARIABLE = /\b0x\h+\b|\b\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\b|\b\h{16,}\b|[0-9]+(?:\.[0-9]+)?|\S+@\S+\.\w+/
    FNV_OFFSET = 0xcbf29ce484222325
    FNV_PRIME = 0x100000001b3
    MASK = 0xffffffffffffffff

    def initialize(options)
      options = options.to_h.transform_keys(&:to_sym)
      @burst = [options.fetch(:per_issue_burst, 10).to_i, 1].max
      @per_issue_per_minute = [options.fetch(:per_issue_per_minute, 1).to_f, 0.0].max
      @per_minute = [options.fetch(:per_minute, 600).to_f, 1.0].max
      @enabled = options.fetch(:enabled, true)
      @all = { tokens: @per_minute, updated: now, suppressed: 0 }
      @issues = {}
      @lock = Mutex.new
    end

    # Whether an event of the issue may be sent: nil when not, else the occurrences held back
    # since the last one sent.
    def allow(issue, at = now)
      return 0 unless @enabled

      @lock.synchronize do
        bucket = @issues.delete(issue) || { tokens: @burst.to_f, updated: at, suppressed: 0 }
        @issues.shift if @issues.size >= MAX_ISSUES # the least recently seen goes
        @issues[issue] = bucket
        if take(bucket, @burst, @per_issue_per_minute, at) && take(@all, @per_minute, @per_minute, at)
          held = bucket[:suppressed]
          bucket[:suppressed] = 0
          held
        else
          bucket[:suppressed] += 1
          nil
        end
      end
    end

    # For tests: makes the issue's bucket older.
    def age(issue, seconds)
      @lock.synchronize { @issues[issue][:updated] -= seconds if @issues.key?(issue) }
    end

    # The event's fingerprint for the budget: its exception types and top in-app frames (or its
    # message without the parts that vary), and its custom fingerprint.
    def self.issue_of(event)
      parts = []
      if event.exceptions.any?
        parts.concat(event.exceptions.map(&:type))
        thrower = event.exceptions.last # the innermost threw: its frames say where
        frames = thrower.frames.empty? ? event.exceptions.first.frames : thrower.frames
        app = frames.select(&:in_app)
        app = frames if app.empty?
        app.last(TOP_FRAMES).each { |f| parts << "#{f.module}|#{f.function}" }
        parts << event.exceptions.first.message.to_s.gsub(VARIABLE, "<*>") if frames.empty?
      else
        parts << event.message.to_s.gsub(VARIABLE, "<*>")
      end
      parts << event.fingerprint.join("\x1f") if event.fingerprint.any?
      fnv1a(parts.join("\x1e"))
    end

    def self.fnv1a(text)
      hash = FNV_OFFSET
      text.each_byte { |b| hash = ((hash ^ b) * FNV_PRIME) & MASK }
      format("%016x", hash)
    end

    private

    def take(bucket, burst, per_minute, at)
      bucket[:tokens] = [burst.to_f, bucket[:tokens] + ((at - bucket[:updated]) / 60.0 * per_minute)].min
      bucket[:updated] = at
      return false if bucket[:tokens] < 1

      bucket[:tokens] -= 1
      true
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # @api private request sessions, counted per minute and user, sent as aggregates.
  class Sessions
    def initialize
      @buckets = {}
      @lock = Mutex.new
    end

    def record(status, device_id, at)
      minute = (at / 60).floor * 60
      @lock.synchronize do
        bucket = (@buckets[[minute, device_id]] ||= { minute: minute, did: device_id, counts: [0, 0, 0] })
        bucket[:counts][{ "crashed" => 2, "errored" => 1 }.fetch(status, 0)] += 1
      end
    end

    def empty? = @lock.synchronize { @buckets.empty? }

    # What was counted, as the protocol's body, and a fresh start; nil when nothing was.
    def take(options)
      buckets = @lock.synchronize do
        taken = @buckets
        @buckets = {}
        taken
      end
      return nil if buckets.empty?

      aggregates = buckets.values.map do |b|
        aggregate = { "started" => Time.at(b[:minute]).utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
        aggregate["did"] = b[:did] if b[:did]
        aggregate.merge("exited" => b[:counts][0], "errored" => b[:counts][1], "crashed" => b[:counts][2])
      end
      { "sdk" => Fixwire.sdk, "release" => options.release, "environment" => options.environment, "aggregates" => aggregates }
    end

    # The first 16 bytes of SHA-256 of the user's id (else email, else name), as hex.
    def self.device_id(user)
      id = [user&.id, user&.email, user&.username].find { |v| !v.nil? && !v.to_s.strip.empty? }
      id && Digest::SHA256.hexdigest(id.to_s)[0, 32]
    end
  end
end
