# frozen_string_literal: true

require "net/http"
require "json"
require "zlib"
require "stringio"

module Fixwire
  # Sends a request to Fixwire: #send_request(url, body, headers) returns [status, headers], the
  # status 0 when there was no answer (an "error" header then says why), header names in lower case.
  module Transport
    # Over Net::HTTP. The SDK's own requests are not traced.
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
          response = http.request(request)
          [response.code.to_i, response.each_header.to_h]
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
  # A request with no answer or a 5xx is retried twice with backoff; rate limits pause the kind of
  # data they name. After a fork, the child starts a worker of its own.
  class Worker
    BATCH = 100
    LINGER = 1.0
    SESSIONS_EVERY = 60.0
    RETRIES = [0.5, 2.0].freeze

    def initialize(client)
      @client = client
      @lock = Mutex.new
      @paused = {}
      start
    end

    # Queues an item: [:log, record], [:span, record] or [:request, path, category, body]. False when
    # the queue is full.
    def push(item)
      restart if Process.pid != @pid
      if @queue.size >= @client.options.max_queue
        @client.log("dropping: the queue is full")
        return false
      end
      @queue << item
      true
    end

    # Waits until everything queued before it was sent (or dropped), at most timeout seconds.
    def flush(timeout)
      restart if Process.pid != @pid
      done = Queue.new
      @queue << [:flush, done]
      done.pop(timeout: timeout) == true
    end

    private

    def start
      @pid = Process.pid
      @queue = Queue.new
      @thread = Thread.new { run }
      @thread.name = "fixwire-worker"
      @thread.report_on_exception = false
    end

    def restart
      @lock.synchronize { start if Process.pid != @pid }
    end

    def run
      logs = []
      spans = []
      since = nil
      sessions_at = now
      loop do
        wait = since ? [LINGER - (now - since), 0].max : SESSIONS_EVERY
        item = @queue.pop(timeout: wait)
        case item&.first
        when :log then logs << item[1]
        when :span then spans << item[1]
        when :request then post(item[1], item[2], item[3])
        when :flush
          send_batches(logs, spans)
          send_sessions
          sessions_at = now
          item[1] << !@unsent # whether everything since the last flush went out
          @unsent = false
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
      rescue StandardError => e
        @client.log("the worker failed, going on: #{e.message}") # never dies
      end
    end

    def send_batches(logs, spans)
      logs.each_slice(BATCH) { |batch| post("/v1/logs", "error", Otlp.logs(@client.options, batch)) }
      spans.each_slice(BATCH) { |batch| post("/v1/traces", "span", Otlp.traces(@client.options, batch)) }
      logs.clear
      spans.clear
    end

    def send_sessions
      body = @client.sessions&.take(@client.options)
      post("/v1/sessions", "session", body) if body
    end

    def post(path, category, body)
      if paused?(category)
        @client.log("dropping a #{category} request: rate limited")
        @unsent = true
        return false
      end
      json = gzip(JSON.generate(body))
      headers = { "Authorization" => "Bearer #{@client.dsn.key}", "Content-Type" => "application/json",
                  "Content-Encoding" => "gzip", "User-Agent" => "#{SDK_NAME}/#{VERSION}" }
      status = 0
      answer = {}
      [0, *RETRIES].each do |delay|
        sleep(delay) if delay.positive?
        status, answer = @client.transport.send_request(@client.dsn.url(path), json, headers)
        answer = answer.to_h.transform_keys { |k| k.to_s.downcase }
        limit(answer["fixwire-rate-limits"], status, answer["retry-after"])
        return true if status.between?(200, 299)
        break if status.positive? && status < 500 # refused: retrying won't help

        break if paused?(category)
      end
      @client.log("dropping a #{category} request (#{status}#{": #{answer["error"]}" if answer["error"]})")
      @unsent = true
      false
    rescue StandardError => e
      @client.log("sending to #{path} failed: #{e.message}")
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

    def paused?(category)
      @lock.synchronize { [@paused[category], @paused[""]].compact.any? { |until_| until_ > now } }
    end

    # Fixwire-Rate-Limits: "60:error;span, 30:" (seconds and categories; none means all). A 429
    # without it pauses everything for Retry-After, at least a minute.
    def limit(header, status, retry_after)
      header = "#{[retry_after.to_i, 60].max}:" if header.nil? && status == 429
      return if header.nil?

      header.split(",").each do |part|
        seconds, categories = part.strip.split(":", 2)
        next unless seconds.to_i.positive?

        names = categories.to_s.strip.empty? ? [""] : categories.split(";").map(&:strip)
        @lock.synchronize { names.each { |c| @paused[c] = [@paused[c] || 0, now + seconds.to_i].max } }
      end
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
