# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# What hostile or outsized input can't do: hang the app, sink a batch, leak past redaction or
# travel on to other services.
class LimitsTest < Minitest::Test
  include FixwireTestCase

  # Fake credentials, apart from their names so that secret scanners don't take them for real.
  GOOGLE = "ya29.a0AfH6SMBx"
  CLIENT = "GOCSPX-x1y2z3"

  def test_fingerprints_hostile_messages_quickly
    started = now
    ["1@" * 50_000, "@1" * 50_000, "1-" * 50_000, "0x" * 50_000].each do |message|
      Fixwire::Budget.issue_of(Fixwire::Event.new(message: message))
    end

    assert_operator now - started, :<, 1
    @ingest.init

    refute_nil Fixwire.capture_message("caf\xC3 au lait".dup.force_encoding(Encoding::UTF_8)), "broken UTF-8 is sent too"
  end

  def test_cuts_cycles_in_what_is_sent
    @ingest.init
    tree = { "name" => "root", "children" => [] }
    30.times { |i| tree["children"] << { "name" => "node #{i}", "parent" => tree, "children" => [] } }
    Fixwire.set_context("tree", tree)
    started = now
    Fixwire.capture_message("tree")

    assert_operator now - started, :<, 1
    Fixwire.flush
    sent = attrs(@ingest.log_records.first)["fixwire.contexts"]["tree"]

    assert_equal ["node 0", "[Circular ~]"], sent["children"][0].values_at("name", "parent")
  end

  def test_an_oversized_record_never_takes_its_batch_along
    @ingest.init(traces_sample_rate: 1.0, max_value_length: 6_000_000)
    Fixwire.capture_message("fine")
    Fixwire.capture_message("x" * 1_100_000)
    10.times { |i| Fixwire.add_breadcrumb(category: "import", message: "#{i} #{"y" * 120_000}") }
    Fixwire.set_context("cart", { "id" => 1 })
    Fixwire.capture_message("with heavy breadcrumbs")
    Fixwire.with_scope do
      Fixwire.set_context("import", { "rows" => "r" * 1_100_000 })
      Fixwire.capture_message("with heavy breadcrumbs and contexts")
    end
    Fixwire.trace("import") do
      12.times { |i| Fixwire.start_span("chunk #{i}", attributes: { "data" => "z" * 500_000 }).finish }
      Fixwire.start_span("too big", attributes: { "data" => "z" * 5_000_000 }).finish
    end

    refute Fixwire.flush(10), "the record over 1 MB was dropped"
    records = @ingest.log_records

    assert_equal(["fine", "with heavy breadcrumbs", "with heavy breadcrumbs and contexts"],
                 records.map { |r| FakeIngest.value(r["body"]) })
    refute attrs(records[1]).key?("fixwire.breadcrumbs"), "sent without its breadcrumbs"
    assert attrs(records[1]).key?("fixwire.contexts"), "but with its contexts"
    refute attrs(records[2]).key?("fixwire.contexts"), "then without its contexts too"
    traces = @ingest.requests("/v1/traces")

    assert_equal 13, @ingest.spans.size, "the span that can't fit is dropped alone"
    assert_operator traces.size, :>=, 2
    assert(traces.all? { |r| JSON.generate(r[:body]).bytesize <= 5_000_000 })
  end

  def test_cuts_strings_to_max_value_length
    @ingest.init
    pem = "-----BEGIN RSA PRIVATE KEY-----\n#{"MIIE" * 1000}\n-----END RSA PRIVATE KEY-----"
    ["é" * 600, "a" * 1024, "a" * 1025, "#{"a" * 1000} #{pem}"].each { |m| Fixwire.capture_message(m) }
    Fixwire.set_extra("k" * 2000, "v" * 2000)
    Fixwire.capture_message("long key")
    Fixwire.flush
    bodies = @ingest.log_records.map { |r| FakeIngest.value(r["body"]) }

    assert_equal "#{"é" * 510}...", bodies[0], "UTF-8 bytes, cut on a character boundary"
    assert_equal ["a" * 1024, "#{"a" * 1021}..."], bodies[1, 2]
    assert_equal "#{"a" * 1000} [REDACTED:private_key]", bodies[3], "masked before the cut"
    assert_equal({ "#{"k" * 1021}..." => "#{"v" * 1021}..." }, attrs(@ingest.log_records.last).select { |k, _| k.start_with?("k") })
    assert(@ingest.log_records.all? { |r| r["body"]["stringValue"].bytesize <= 1024 })
  end

  def test_cuts_strings_without_redaction_too
    @ingest.init(redact: false, max_value_length: 10)
    Fixwire.capture_message("ada@example.com")
    Fixwire.flush

    assert_equal "ada@exa...", FakeIngest.value(@ingest.log_records.first["body"])
  end

  def test_walks_values_within_limits
    @ingest.init
    deep = { "v" => "end" }
    12.times { deep = { "n" => deep } }
    unreadable = Object.new
    def unreadable.to_s = raise("no")
    Fixwire.set_extra("deep", deep)
    Fixwire.set_extra("wide", (1..150).to_a)
    Fixwire.set_extra("many", Array.new(200) { Array.new(100) { [] } })
    Fixwire.set_extra("odd", { "unreadable" => unreadable, "nan" => Float::NAN, "inf" => Float::INFINITY, "-inf" => -Float::INFINITY })
    Fixwire.capture_message("values")
    Fixwire.flush
    a = attrs(@ingest.log_records.first)

    assert_equal "[Object]", a["deep"].dig(*Array.new(10, "n")), "10 levels, then a marker"
    assert_equal (1..100).to_a, a["wide"]
    assert_equal [Array.new(100, []), "[Array]"], a["many"].values_at(98, 99), "10,000 objects walked"
    assert_equal({ "unreadable" => "[Unreadable]", "nan" => "NaN", "inf" => "Infinity", "-inf" => "-Infinity" }, a["odd"])
  end

  def test_keeps_the_newest_frames
    @ingest.init
    Fixwire.capture_exception(raised { dig(150) })
    Fixwire.flush
    @ingest.init(max_stack_frames: 5)
    Fixwire.capture_exception(raised { dig(150) })
    Fixwire.flush
    frames = @ingest.log_records.map { |r| attrs(r)["fixwire.exceptions"][0]["frames"] }

    assert_equal [100, 5], frames.map(&:size)
    assert(frames.flatten.all? { |f| f["function"] == "dig" }, "the deepest calls, not the test runner's")
    assert_equal ['raise "deep"', "return dig(depth - 1) if depth.positive?"],
                 frames[0].last(2).reverse.map { |f| f["context_line"].strip }, "the newest last"
  end

  def test_chains_at_most_ten_causes
    @ingest.init
    Fixwire.capture_exception(raised { nest(10) })
    Fixwire.flush
    chain = attrs(@ingest.log_records.first)["fixwire.exceptions"]

    assert_equal 10, chain.size, "of 11"
    assert_equal(["error 10", "error 1"], chain.values_at(0, -1).map { |x| x["message"] })
  end

  def test_caps_span_attributes
    @ingest.init(traces_sample_rate: 1.0)
    span = Fixwire.start_span("wide", op: "task", attributes: (1..100).to_h { |i| ["a#{i}", i] })
    (101..200).each { |i| span.set_attribute("a#{i}", i) }
    span.set_attribute("a1", "changed")
    span.finish
    Fixwire.flush
    a = attrs(@ingest.spans.first)

    assert_equal 128, a.size
    assert_equal %w[changed task], a.values_at("a1", "fixwire.op")
    refute a.key?("a128"), "127 of the span's own, and its operation"
  end

  def test_counts_at_most_5000_users_apart_per_send
    sessions = Fixwire::Sessions.new
    5001.times { |i| sessions.record("ok", "user-#{i}", 0) }
    5000.times { |i| sessions.record("ok", "user-#{i}", 60) }
    body = sessions.take(Fixwire::Options.new.apply_defaults!)

    assert_equal 10_001, body["aggregates"].size
    assert_equal 1, body["aggregates"].count { |a| a["did"].nil? }, "the 5001st user counted without the user"
    @ingest.init(release: "shop@1.0.0", auto_session_tracking: true)
    10_001.times { |i| Fixwire.client.sessions.record("ok", "user-#{i % 5000}", 60 * (i / 5000)) }
    Fixwire.flush

    assert_equal([5000, 5000, 1], @ingest.requests("/v1/sessions").map { |r| r[:body]["aggregates"].size })
  end

  def test_masks_every_string_sent
    @ingest.init(traces_sample_rate: 1.0)
    Fixwire.configure_scope do |scope|
      scope.request = Fixwire::Request.new(http_method: "GET", url: "https://shop.test/cb", query: "state=x&code=4%2F0AX4XfWh7Qa")
    end
    Fixwire.set_extra("ada@example.com", "a key")
    Fixwire.add_breadcrumb(category: "http", data: { "url" => "https://api.test/?access_token=#{GOOGLE}" })
    Fixwire.trace("GET /cb?client_secret=#{CLIENT}") { Fixwire.capture_message("x") }
    Fixwire.capture_feedback(message: "my password=hunter2hunter2", score: -1)
    Fixwire.flush
    a = attrs(@ingest.log_records.first)

    assert_equal "state=x&code=[REDACTED:secret_assignment]", a["url.query"]
    assert_equal "a key", a["[REDACTED:email]"], "keys too"
    assert_equal "https://api.test/?access_token=[REDACTED:secret_assignment]", a["fixwire.breadcrumbs"][0]["data"]["url"]
    assert_equal "GET /cb?client_secret=[REDACTED:secret_assignment]", @ingest.spans.first["name"]
    assert_equal "my password=[REDACTED:secret_assignment]", @ingest.requests("/v1/feedback").first[:body]["message"]
  end

  def test_masks_the_status_of_failed_spans
    @ingest.init(traces_sample_rate: 1.0)
    assert_raises(ArgumentError) { Fixwire.trace("charge") { raise ArgumentError, "card of ada@example.com declined" } }
    Fixwire.flush

    assert_equal "card of [REDACTED:email] declined", @ingest.spans.first["status"]["message"]
  end

  def test_passes_no_oversized_trace_state_on
    @ingest.init(traces_sample_rate: 1.0)
    traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    big = Fixwire.continue_trace(traceparent, "v=#{"a" * 600}", "k=#{"b" * 9000}", "big")
    small = Fixwire.start_span("small")

    assert_equal [nil, nil, nil], [big.tracestate, big.baggage, small.baggage]
    small.finish
    big.finish
    span = Fixwire.continue_trace(traceparent, "v=1", "k=2", "fine")

    assert_equal %w[v=1 k=2], [span.tracestate, span.baggage]
    span.finish
    at = ->(size) { "v=#{"a" * (size - 2)}" }
    sizes = [[512, 8192], [513, 8193]].map do |state, baggage|
      span = Fixwire.continue_trace(traceparent, at.call(state), at.call(baggage), "limits")
      span.finish
      [span.tracestate&.bytesize, span.baggage&.bytesize]
    end

    assert_equal [[512, 8192], [nil, nil]], sizes, "dropped whole, not cut"
    ["v=1\nx=2", "v=1\x00", "v=\x7F"].each do |control|
      span = Fixwire.continue_trace(traceparent, control, control, "control")
      span.finish

      assert_equal [nil, nil], [span.tracestate, span.baggage], control.inspect
    end
  end

  def test_continues_only_well_formed_traceparents
    good = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

    refute_nil Fixwire::Span.parse_traceparent(good)
    ["01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "#{good}-extra", "00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01",
     "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b-01", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1",
     "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0g", "00-4bf92f3577b34da6a3ce929d0e0e47g6-00f067aa0ba902b7-01",
     nil, 42].each do |bad|
      assert_nil Fixwire::Span.parse_traceparent(bad), bad.inspect
    end
  end

  def test_propagates_traces_to_the_targets_only
    targets = ["example.com", "inventory.test:8443", "https://api.shop.test/v2", "/internal", /billing\.(test|local)/]
    @ingest.init(trace_propagation_targets: targets)
    client = Fixwire.client
    yes = ["https://example.com/", "http://api.example.com/x", "https://API.Example.COM/x", "https://inventory.test:8443/stock",
           "https://eu.inventory.test:8443/stock", "https://api.shop.test/v2/orders", "https://user:pw@api.shop.test/v2/orders",
           "/internal/health", "http://billing.local/charge"]
    no = ["https://badexample.com/", "https://example.com.evil.net/", "https://inventory.test/stock", "https://inventory.test:443/",
          "https://api.shop.test/v1", "https://api.shop.test/x?u=https://api.shop.test/v2", "https://evil.test/#https://api.shop.test/v2",
          "https://other.test/internal", "https://other.test/?to=billing.test", "not a url at all"]

    assert_equal yes.map { true }, yes.map { |url| client.propagate_to?(url) }, yes
    assert_equal no.map { false }, no.map { |url| client.propagate_to?(url) }, no
    @ingest.init

    refute Fixwire.client.propagate_to?("https://example.com/"), "no targets: no headers"
  end

  def test_clamps_what_rate_limits_ask
    @ingest.answer = ->(_n, _path) { [200, { "Fixwire-Rate-Limits" => "#{"9" * 40}:error;whatever, 12abc:span, 86401:feedback" }] }
    @ingest.init
    Fixwire.capture_message("first")
    Fixwire.flush
    paused = worker.instance_variable_get(:@paused)

    assert_equal %w[error feedback], paused.keys, "broken seconds and unknown categories are ignored"
    assert_in_delta 86_400, paused["error"] - now, 5
    assert_in_delta 86_400, paused["feedback"] - now, 5
  end

  def test_reads_retry_after_as_seconds_or_a_date
    assert_equal([0, 60, 86_400, 86_400, nil, nil, nil],
                 ["0", "60", "86400", "86401", "-5", "soon", nil].map { |v| Fixwire::Worker.seconds(v) })
    assert_in_delta 3600, Fixwire::Worker.seconds((Time.now + 3600).httpdate), 2
    assert_equal 0, Fixwire::Worker.seconds((Time.now - 3600).httpdate), "a date gone by"
    @ingest.answer = ->(_n, _path) { [429, { "Retry-After" => (Time.now + 7200).httpdate }] }
    @ingest.init
    Fixwire.capture_message("limited")
    Fixwire.flush

    assert_in_delta 7200, worker.send(:paused_for, "feedback"), 5, "a 429 without Fixwire-Rate-Limits pauses all"
    assert_equal 1, @ingest.requests("/v1/logs").size, "and is not retried"
  end

  def test_retries_three_times_waiting_twice_as_long_each_time
    [[503, {}], [0, { "error" => "connection refused" }]].each do |answer|
      times = []
      @ingest = FakeIngest.new
      @ingest.answer = lambda do |_n, _path|
        times << now
        answer
      end
      @ingest.init
      worker.retry_first = 0.05
      Fixwire.capture_message("down")

      refute Fixwire.flush(5), "dropped after the last try"
      gaps = times.each_cons(2).map { |a, b| b - a }
      doubling = gaps.zip([0.05, 0.1, 0.2]).all? { |gap, wait| gap >= wait && gap < wait + 0.5 }

      assert_equal 4, times.size, "the first try and 3 more"
      assert doubling, "waits of #{gaps.inspect}"
    end
  end

  def test_a_5xx_with_retry_after_pauses_everything
    @ingest.answer = ->(n, _path) { n.zero? ? [503, { "Retry-After" => "1" }] : [200, {}] }
    @ingest.init
    worker.retry_first = 0.01
    started = now
    Fixwire.capture_message("first")

    refute Fixwire.flush(0.3), "its retry waits for the pause"
    refute_nil Fixwire.capture_feedback(score: 1) # dropped: everything is paused
    refute Fixwire.flush(5)
    assert_operator now - started, :>=, 1
    assert_equal [2, 0], [@ingest.requests("/v1/logs").size, @ingest.requests("/v1/feedback").size]
  end

  def test_drops_what_would_wait_more_than_five_minutes
    @ingest.answer = ->(_n, _path) { [503, { "Retry-After" => "301" }] }
    @ingest.init
    Fixwire.capture_message("first")

    refute Fixwire.flush(2)
    assert_equal 1, @ingest.requests("/v1/logs").size
    assert_in_delta 301, worker.send(:paused_for, "span"), 5
  end

  def test_follows_no_redirect_and_keeps_few_retries
    @ingest.answer = ->(_n, _path) { [307, { "Location" => "https://elsewhere.test/v1/logs" }] }
    @ingest.init
    Fixwire.capture_message("moved")

    refute Fixwire.flush(2), "a 3xx is a refusal"
    assert_equal 1, @ingest.requests.size
    @ingest.answer = ->(_n, _path) { [503, {}] }
    @ingest.init(max_queue: 1)
    worker.retry_first = 10
    2.times do |i|
      Fixwire.capture_feedback(score: 1, message: "try #{i}")
      Fixwire.flush(0.3)
    end

    assert_equal 1, worker.instance_variable_get(:@retries).size, "as many wait for a retry as max_queue"
    assert_equal 2, @ingest.requests("/v1/feedback").size
    assert_equal 100, Fixwire::Options.new.apply_defaults!.max_queue
  end

  def test_leaves_the_answers_body_unread
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      socket.readpartial(65_536)
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 1000000000\r\n\r\n#{"x" * 1000}")
      sleep 10 # the rest never comes
    ensure
      socket&.close
    end
    started = now
    status, = Fixwire::Transport::HTTP.new(3).send_request("http://127.0.0.1:#{server.addr[1]}/v1/logs", "{}", {})

    assert_equal 200, status
    assert_operator now - started, :<, 1
  ensure
    thread&.kill
    server&.close
  end

  def test_rack_requests_it_cannot_read_go_on_untracked
    @ingest.init
    app = lambda do |env|
      env["fixwire.route"] = :orders
      [200, {}, ["ok"]]
    end
    middleware = Fixwire::Rack::Middleware.new(app)
    env = { "REQUEST_METHOD" => "GET", "rack.url_scheme" => "http", "SERVER_NAME" => "shop", "SERVER_PORT" => "80",
            "SCRIPT_NAME" => "/café", "PATH_INFO" => "/\xFF".b }

    assert_equal 200, middleware.call(env).first, "text in clashing encodings"
    assert_equal 200, middleware.call(env.merge("SCRIPT_NAME" => "", "PATH_INFO" => "/orders")).first, "a route that is a symbol"
  end

  private

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def worker = Fixwire.client.instance_variable_get(:@worker)

  def raised
    yield
  rescue StandardError => e
    e
  end

  def dig(depth)
    return dig(depth - 1) if depth.positive?

    raise "deep"
  end

  # error depth, caused by error depth - 1, … by error 0
  def nest(depth)
    raise "error 0" if depth.zero?

    begin
      nest(depth - 1)
    rescue RuntimeError
      raise "error #{depth}"
    end
  end
end
