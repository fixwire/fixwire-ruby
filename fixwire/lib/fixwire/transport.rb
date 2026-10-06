# frozen_string_literal: true

require "net/http"
require "json"
require "time"
require "zlib"
require "stringio"

module Fixwire
  # Sends a request to Fixwire: #send_request(url, body, headers) returns [status, headers], the
  # status 0 when there was no answer (an "error" header then says why), header names in lower case.
  module Transport
    # Over Net::HTTP, which follows no redirect (the key goes to the DSN's host only). The SDK's own
    # requests are not traced.
    class HTTP
      def initialize(timeout)
        @timeout = timeout
      end

      def send_request(url, body, headers)
        uri = URI(url)
        Thread.current[:__fixwire_sending] = true
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: [@timeout, 2].min,
                                            read_timeout: @timeout, write_timeout: @timeout) do |http|
          request = Net::HTTP::Post.new(uri.request_uri, headers)
          request.body = body
          # The status and headers say all the SDK needs: the body is left unread, however large.
          http.request(request) { |response| return [response.code.to_i, response.each_header.to_h] }
        end
      rescue StandardError => e # Net::OpenTimeout and the like too
        [0, { "error" => "#{e.class}: #{e.message}" }]
      ensure
        Thread.current[:__fixwire_sending] = nil
      end
    end
  end

  # @api private sends from a background thread, so that capturing never waits: log records and
  # spans in batches (100, or every second), check-ins and feedback at once, sessions every minute.
  # A request with no answer or a 5xx is tried again up to 3 times, after 1, 2 and 4 seconds (or
  # once a pause is over, when that is later), unless that is more than 5 minutes away; rate limits
  # pause the kind of data they name. After a fork, the child starts a worker of its own.
  class Worker
    BATCH = 100
    LINGER = 1.0
    SESSIONS_EVERY = 60.0
    RETRIES = 3
    RETRY_FIRST = 1.0
    MAX_WAIT = 300
    # The protocol's limits, as JSON: an error or a message, a request of log records or spans, and
    # session aggregates per request (about 110 bytes each, at most 1 MB).
    MAX_RECORD = 1_000_000
    MAX_REQUEST = 5_000_000
    MAX_AGGREGATES = 5000
    # What an error or a message over MAX_RECORD leaves out, one after the other, before it is
    # dropped (Ruby's frames hold no local variables).
    SHED = %w[fixwire.breadcrumbs fixwire.contexts].freeze
    # The longest a rate limit pauses anything, and the kinds of data it may name.
    MAX_PAUSE = 86_400
    CATEGORIES = %w[error log span session check_in feedback file].freeze

    # Restarts the main client's worker in a forked child at once (Puma's and Unicorn's workers), so
    # that a child sends its sessions even when it captures nothing.
    module ForkHook
      def _fork
        pid = super
        Hub.main&.client&.forked if pid.zero?
        pid
      end
    end

    # @api private the first retry's wait (tests shorten it)
    attr_accessor :retry_first

    def initialize(client)
      @client = client
      @lock = Mutex.new
      @paused = {}
      @retry_first = RETRY_FIRST
      start
      Process.singleton_class.prepend(ForkHook) unless Process.singleton_class < ForkHook
    end

    # In a forked child: a worker of its own, without the parent's sessions (the parent sends them).
    def restart
      @lock.synchronize do
        if Process.pid != @pid
          @client.sessions&.clear
          start
        end
      end
    end

    # Queues an item: [:log, record], [:spans, records] (a segment's) or [:request, path, category,
    # body]. False when max_queue items wait already.
    def push(item)
      restart if Process.pid != @pid
      if @queue.size >= @client.options.max_queue
        @client.log("dropping: the queue is full")
        return false
      end
      @queue << item
      true
    end

    # Waits until everything queued before it was sent (or dropped), retries included, at most
    # timeout seconds.
    def flush(timeout)
      restart if Process.pid != @pid
      done = Queue.new
      @queue << [:flush, done]
      done.pop(timeout: timeout) == true
    end

    # Seconds from 0 to MAX_PAUSE in a header: whole seconds or, with dates, an HTTP date
    # (Retry-After); nil when it is missing or broken.
    def self.seconds(value, dates: true)
      text = value.to_s.strip
      seconds = if text.match?(/\A[0-9]+\z/) then text.size > 9 ? MAX_PAUSE : text.to_i
                elsif dates && !text.empty? then (Time.httpdate(text) - Time.now).ceil
                end
      seconds&.clamp(0, MAX_PAUSE)
    rescue ArgumentError
      nil
    end

    private

    def start
      @pid = Process.pid
      @queue = Queue.new
      @retries = [] # [due, tries, path, category, body], at most max_queue
      @flushes = []
      @thread = Thread.new { run }
      @thread.name = "fixwire-worker"
      @thread.report_on_exception = false
    end

    def run
      logs = []
      spans = []
      since = nil
      sessions_at = now
      loop do
        wait = since ? LINGER - (now - since) : SESSIONS_EVERY - (now - sessions_at)
        wait = [wait, *@retries.map { |r| r[0] - now }].min.clamp(0, SESSIONS_EVERY)
        item = @queue.pop(timeout: wait)
        case item&.first
        when :log then logs << item[1]
        when :spans then spans.concat(item[1])
        when :request then post(item[1], item[2], item[3])
        when :flush
          send_batches(logs, spans)
          send_sessions
          sessions_at = now
          @flushes << item[1]
        end
        since ||= now if logs.any? || spans.any?
        if logs.size >= BATCH || spans.size >= BATCH || (since && now - since >= LINGER)
          send_batches(logs, spans)
          since = nil
        end
        if now - sessions_at >= SESSIONS_EVERY
          send_sessions
          sessions_at = now
        end
        send_retries
        settle_flushes
      rescue StandardError => e
        @client.log("the worker failed, going on: #{e.message}") # never dies
      end
    end

    # Answers the flushes waiting once no request waits for a retry: whether everything since the
    # last flush went out.
    def settle_flushes
      return if @flushes.empty? || @retries.any?

      @flushes.each { |done| done << !@unsent }
      @flushes.clear
      @unsent = false
    end

    def send_batches(logs, spans)
      room = MAX_REQUEST - Otlp.logs(@client.options, []).bytesize
      batches(logs.filter_map { |r| encode(r, MAX_RECORD) }, room) { |batch| post("/v1/logs", "error", Otlp.logs(@client.options, batch)) }
      room = MAX_REQUEST - Otlp.traces(@client.options, []).bytesize
      batches(spans.filter_map { |r| encode(r, room) }, room) { |batch| post("/v1/traces", "span", Otlp.traces(@client.options, batch)) }
      logs.clear
      spans.clear
    end

    # Records as JSON in batches of at most BATCH records and room bytes.
    def batches(records, room)
      batch = []
      size = 0
      records.each do |json|
        if batch.size >= BATCH || (batch.any? && size + json.bytesize > room)
          yield batch
          batch = []
          size = 0
        end
        batch << json
        size += json.bytesize + 1
      end
      yield batch if batch.any?
    end

    # A record as JSON, or nil when it can't go: over its limit, an error leaves out what SHED
    # names until it fits. One that fails or is too large never takes its batch along.
    def encode(record, limit)
      json = JSON.generate(record)
      SHED.each do |key|
        break if json.bytesize <= limit

        attributes = record["attributes"]
        next unless attributes&.any? { |a| a["key"] == key }

        record = record.merge("attributes" => attributes.reject { |a| a["key"] == key })
        json = JSON.generate(record)
      end
      return json if json.bytesize <= limit

      @client.log("dropping a record of #{json.bytesize} bytes: the limit is #{limit}")
      @unsent = true
      nil
    rescue StandardError => e
      @client.log("dropping a record: #{e.message}")
      @unsent = true
      nil
    end

    def send_sessions
      body = @client.sessions&.take(@client.options)
      return unless body

      body = Otlp.cut(body, @client.options.max_value_length) # the release and environment
      body["aggregates"].each_slice(MAX_AGGREGATES) { |part| post("/v1/sessions", "session", body.merge("aggregates" => part)) }
    end

    def post(path, category, body)
      return drop(category, "paused") if paused?(category)

      attempt(0, path, category, gzip(body.is_a?(String) ? body : JSON.generate(body)))
    rescue StandardError => e
      drop(category, "sending to #{path} failed: #{e.message}")
    end

    # Sends a request (gzipped); one without an answer or with a 5xx waits for its next try.
    def attempt(tries, path, category, body)
      headers = { "Authorization" => "Bearer #{@client.dsn.key}", "Content-Type" => "application/json",
                  "Content-Encoding" => "gzip", "User-Agent" => "#{SDK_NAME}/#{VERSION}" }
      status, answer = @client.transport.send_request(@client.dsn.url(path), body, headers)
      answer = answer.to_h.transform_keys { |k| k.to_s.downcase }
      limit(answer, status)
      return true if status.between?(200, 299)

      # A 3xx or a 4xx is a refusal: trying again won't help.
      if (status.zero? || status >= 500) && tries < RETRIES
        later([@retry_first * (2**tries), paused_for(category)].max, tries + 1, path, category, body)
      else
        drop(category, "#{status}#{": #{answer["error"]}" if answer["error"]}")
      end
    end

    # Keeps a request for another try in wait seconds: not when that is more than MAX_WAIT away,
    # nor past max_queue requests waiting.
    def later(wait, tries, path, category, body)
      return drop(category, "its next try is #{wait.round} s away") if wait > MAX_WAIT
      return drop(category, "too many requests wait for a retry") if @retries.size >= @client.options.max_queue

      @retries << [now + wait, tries, path, category, body]
      false
    end

    # Tries the requests whose time has come; one paused in the meantime waits for the pause.
    def send_retries
      due, @retries = @retries.partition { |r| r[0] <= now }
      due.each do |_, tries, path, category, body|
        paused = paused_for(category)
        paused.positive? ? later(paused, tries, path, category, body) : attempt(tries, path, category, body)
      rescue StandardError => e
        drop(category, "sending to #{path} failed: #{e.message}")
      end
    end

    def drop(category, why)
      @client.log("dropping a #{category} request: #{why}")
      @unsent = true
      false
    end

    def gzip(text)
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io, 1)
      gz.write(text)
      gz.close
      io.string
    end

    def paused?(category) = paused_for(category).positive?

    # The seconds a category is still paused for, 0 when it isn't.
    def paused_for(category)
      @lock.synchronize { [@paused[category], @paused[""]].compact.map { |until_| until_ - now }.push(0).max }
    end

    # Pauses what the answer asks. Fixwire-Rate-Limits: "60:error;span, 30:" (seconds and
    # categories, none meaning all); without it, a 429 pauses everything for Retry-After, at least
    # a minute. A 5xx with Retry-After pauses everything for that long. No pause is over a day.
    def limit(answer, status)
      header = answer["fixwire-rate-limits"].to_s
      retry_after = Worker.seconds(answer["retry-after"])
      pause([""], [retry_after || 0, 60].max) if status == 429 && header.strip.empty?
      pause([""], retry_after) if status >= 500 && retry_after
      header.split(",").each do |part|
        seconds, categories = part.strip.split(":", 2)
        seconds = Worker.seconds(seconds, dates: false)
        next if seconds.nil?

        pause(categories.to_s.strip.empty? ? [""] : categories.split(";").map(&:strip) & CATEGORIES, seconds)
      end
    end

    def pause(categories, seconds)
      until_ = now + seconds
      @lock.synchronize { categories.each { |c| @paused[c] = [@paused[c] || 0, until_].max } }
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
