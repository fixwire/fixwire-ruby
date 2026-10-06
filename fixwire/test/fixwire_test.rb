# frozen_string_literal: true

require_relative "test_helper"

module Shop
  class CartError < StandardError; end

  class Cart
    def self.charge_card(amount)
      raise ArgumentError, "amount #{amount} exceeds the limit" if amount > 100
    end

    def checkout(amount)
      Cart.charge_card(amount)
    rescue ArgumentError
      raise CartError, "checkout failed"
    end
  end
end

class FixwireTest < Minitest::Test
  include FixwireTestCase

  def test_parses_dsns
    dsn = Fixwire::Dsn.parse("https://fw_pk_live_abc@ingest.fixwire.io")

    assert_equal ["fw_pk_live_abc", "https://ingest.fixwire.io"], [dsn.key, dsn.base_url]
    assert_equal "http://127.0.0.1:9000/v1/logs", Fixwire::Dsn.parse("http://k@127.0.0.1:9000/").url("/v1/logs")
    assert_equal "https://self.example.com/fixwire", Fixwire::Dsn.parse(" https://k@self.example.com/fixwire ").base_url
    ["", "ingest.fixwire.io", "https://ingest.fixwire.io", "ftp://k@host", "https://@host"].each do |bad|
      assert_raises(ArgumentError, bad) { Fixwire::Dsn.parse(bad) }
    end
  end

  def test_rejects_unknown_options
    assert_raises(ArgumentError) { Fixwire.init(dsm: "typo") }
  end

  def test_does_nothing_without_a_dsn
    with_env("FIXWIRE_DSN" => nil) do
      Fixwire.init

      refute_predicate Fixwire, :initialized?
      assert_nil Fixwire.capture_message("nobody hears this")
    end
  end

  def test_captures_exceptions_with_their_causes
    @ingest.init(release: "shop@1.2.0", environment: "staging", server_name: "web-1")
    Fixwire.set_user(id: "user-1", username: "ada")
    Fixwire.set_tag("plan", "team")
    Fixwire.set_context("order", { id: 42 })
    Fixwire.add_breadcrumb(category: "cart", message: "checkout started")

    id = begin
      Shop::Cart.new.checkout(500)
    rescue Shop::CartError => e
      Fixwire.capture_exception(e)
    end

    assert_equal 32, id.size
    assert Fixwire.flush
    request = @ingest.requests("/v1/logs").first

    assert_equal "Bearer publickey", request[:headers]["Authorization"]
    assert_equal "gzip", request[:headers]["Content-Encoding"]
    assert_equal "fixwire.ruby/#{Fixwire::VERSION}", request[:headers]["User-Agent"]
    resource = FakeIngest.resource(request)

    assert_equal ["shop", "shop@1.2.0", "staging", "web-1", "ruby"],
                 resource.values_at("service.name", "service.version", "deployment.environment.name", "host.name",
                                    "telemetry.sdk.language")

    record = @ingest.log_records.first

    assert_equal ["exception", 17], [record["eventName"], record["severityNumber"]]
    a = attrs(record)

    assert_equal [id, "Shop::CartError", "checkout failed"],
                 a.values_at("fixwire.event_id", "exception.type", "exception.message")
    assert_equal %w[user-1 ada], a.values_at("user.id", "user.name")
    assert_equal({ "plan" => "team" }, a["fixwire.tags"])
    assert_equal({ "order" => { "id" => 42 } }, a["fixwire.contexts"])
    assert_equal "checkout started", a["fixwire.breadcrumbs"].first["message"]
    refute a.key?("fixwire.handled")

    chain = a["fixwire.exceptions"]

    assert_equal([%w[Shop::CartError generic], %w[ArgumentError chained]], chain.map { |x| [x["type"], x["mechanism"]["type"]] })
    thrower = chain[1]["frames"].last

    assert_equal "charge_card", thrower["function"]
    assert_equal "Shop::Cart", thrower["module"] if RUBY_VERSION >= "3.4" # labels name the class from 3.4

    assert_equal ["test/fixwire_test.rb", true], [thrower["file"], thrower["in_app"]], "relative to the project root"
    assert_includes thrower["context_line"], "exceeds the limit"
    assert_equal 5, thrower["pre_context"].size
    assert_equal "checkout", chain[0]["frames"].last["function"]
    gem_frames = chain[0]["frames"].select { |f| f["file"].include?("minitest") }

    refute_empty gem_frames
    assert(gem_frames.none? do |f|
      f["in_app"] || f["file"].start_with?("/")
    end, "gems are not the app's, nor named by machine paths")
  end

  def test_marks_methods_written_in_c_as_not_the_apps
    @ingest.init
    begin
      [].fetch(0)
    rescue IndexError => e
      Fixwire.capture_exception(e)
    end
    Fixwire.flush
    frames = attrs(@ingest.log_records.first)["fixwire.exceptions"][0]["frames"]

    if RUBY_VERSION >= "3.4" # labels name the class from 3.4
      assert_equal [%w[Array fetch], false], [frames.last.values_at("module", "function"), frames.last["in_app"]]
      assert_equal ["test_marks_methods_written_in_c_as_not_the_apps", true], frames[-2].values_at("function", "in_app")
    else
      assert_equal "fetch", frames.last["function"]
    end
  end

  def test_captures_messages_at_their_level
    @ingest.init
    Fixwire.capture_message("disk almost full")
    Fixwire.with_scope do |scope|
      scope.set_level(:warning)
      Fixwire.capture_message("slow query")
    end
    Fixwire.capture_message("on fire", level: :fatal)
    Fixwire.flush
    records = @ingest.log_records

    assert_equal 1, @ingest.requests("/v1/logs").size, "one request for all of them"
    assert_equal "fixwire.message", records[0]["eventName"]
    assert_equal "disk almost full", FakeIngest.value(records[0]["body"])
    assert_equal([9, 13, 21], records.map { |r| r["severityNumber"] })
  end

  def test_before_send_changes_or_drops
    @ingest.init(before_send: lambda do |event|
      next nil if event.message.include?("noise")
      next "not an event" if event.message.include?("odd")

      event.tags["seen"] = "yes"
      event
    end)

    assert_nil Fixwire.capture_message("noise")
    assert_nil Fixwire.capture_message("an odd one")
    refute_nil Fixwire.capture_message("signal")
    Fixwire.flush

    assert_equal([{ "seen" => "yes" }], @ingest.log_records.map { |r| attrs(r)["fixwire.tags"] })
  end

  def test_traces_segments_with_their_spans
    @ingest.init(traces_sample_rate: 1.0)
    root = Fixwire.start_span("POST /checkout", op: "http.server", attributes: { "http.request.method" => "POST" })

    assert_same root, Fixwire.current_span
    result = Fixwire.trace("SELECT carts", op: "db.query") do |query|
      assert_same query, Fixwire.current_span
      assert_equal root.span_id, query.parent_span_id
      query.set_error("deadlock")
      "rows"
    end

    assert_equal "rows", result
    assert_same root, Fixwire.current_span
    Fixwire.capture_message("linked")
    root.finish

    assert_nil Fixwire.current_span
    Fixwire.flush
    spans = @ingest.spans.to_h { |s| [s["name"], s] }

    assert_equal 2, spans.size
    r = spans["POST /checkout"]

    assert_equal [2, 0x101], [r["kind"], r["flags"]]
    refute r.key?("parentSpanId")
    assert_equal %w[http.server POST], attrs(r).values_at("fixwire.op", "http.request.method")
    q = spans["SELECT carts"]

    assert_equal [3, { "code" => 2, "message" => "deadlock" }], [q["kind"], q["status"]]
    record = @ingest.log_records.first

    assert_equal [root.trace_id, root.span_id], record.values_at("traceId", "spanId")
    assert_equal "POST /checkout", attrs(record)["fixwire.transaction"]
  end

  def test_trace_marks_the_span_failed_and_raises_on
    @ingest.init(traces_sample_rate: 1.0)
    assert_raises(KeyError) { Fixwire.trace("load") { raise KeyError, "no sku" } }
    Fixwire.flush

    assert_equal({ "code" => 2, "message" => "no sku" }, @ingest.spans.first["status"])
  end

  def test_continues_callers_traces
    @ingest.init(traces_sample_rate: 0.0)
    span = Fixwire.continue_trace("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "fw=1", "user=1", "GET /")

    assert_equal ["4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7", true],
                 [span.trace_id, span.parent_span_id, span.sampled]
    assert_equal "00-4bf92f3577b34da6a3ce929d0e0e4736-#{span.span_id}-01", span.traceparent
    assert_equal %w[fw=1 user=1], [span.tracestate, span.baggage]
    span.finish
    Fixwire.flush

    assert_equal 0x301, @ingest.spans.first["flags"]
    refute Fixwire.continue_trace("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00", nil, nil, "GET /").sampled
    ["", "00-xyz-00f067aa0ba902b7-01", "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
     "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"].each do |bad|
      assert_nil Fixwire::Span.parse_traceparent(bad), bad
    end
  end

  def test_samples_traces_by_the_shared_rule
    assert Fixwire::Span.sample("4bf92f3577b34da6ffffffffffffffff", 0.01)
    refute Fixwire::Span.sample("4bf92f3577b34da6a000000000000000", 0.5)
    assert Fixwire::Span.sample("4bf92f3577b34da6a080000000000000", 0.5)
    refute Fixwire::Span.sample("4bf92f3577b34da6a07ffffffffff000", 0.5)
    assert Fixwire::Span.sample("4bf92f3577b34da6a000000000000000", 1.0)
    refute Fixwire::Span.sample("4bf92f3577b34da6ffffffffffffffff", 0.0)
  end

  def test_counts_request_sessions
    @ingest.init(release: "shop@1.2.0", auto_session_tracking: true)
    hub = Fixwire.hub
    %w[ok ok handled crash].each_with_index do |outcome, i|
      hub.with_scope do |scope|
        scope.set_user(id: "user-#{i % 2}")
        finish = hub.start_request_session
        Fixwire.capture_exception(RuntimeError.new("x")) if outcome == "handled"
        hub.capture_exception(RuntimeError.new("y"), mechanism: "uncaught", handled: false) if outcome == "crash"
        finish.call
        finish.call # once
      end
    end
    Fixwire.flush
    body = @ingest.requests("/v1/sessions").first[:body]

    assert_equal ["shop@1.2.0", "fixwire.ruby"], [body["release"], body["sdk"]["name"]]
    sums = %w[exited errored crashed].map { |k| body["aggregates"].sum { |a| a[k] } }

    assert_equal [2, 1, 1], sums
    assert_equal 2, body["aggregates"].map { |a| a["did"] }.uniq.size
    assert_includes body["aggregates"].map { |a| a["did"] }, Fixwire::Sessions.device_id(Fixwire::User.new(id: "user-0"))
  end

  def test_sends_check_ins_and_feedback
    @ingest.init(release: "shop@1.2.0")
    config = Fixwire::MonitorConfig.crontab("0 3 * * *", checkin_margin: 5, timezone: "Europe/Berlin")
    assert_raises(RuntimeError) { Fixwire.with_monitor("nightly report", config) { raise "no data" } }
    assert_equal "done", Fixwire.with_monitor("nightly report") { "done" }
    refute_nil Fixwire.capture_feedback(message: "The refund was wrong", score: -3, trace_id: "4bf92f3577b34da6a3ce929d0e0e4736")
    assert_nil Fixwire.capture_feedback(message: "  ")
    Fixwire.flush

    check_ins = @ingest.requests("/v1/check-ins/nightly report").map { |r| r[:body] }

    assert_equal(%w[in_progress error in_progress ok], check_ins.map { |c| c["status"] })
    assert_equal({ "schedule" => { "type" => "crontab", "value" => "0 3 * * *" }, "checkin_margin" => 5, "timezone" => "Europe/Berlin" },
                 check_ins[0]["monitor_config"])
    assert_equal check_ins[0]["check_in_id"], check_ins[1]["check_in_id"]
    assert_predicate check_ins[1]["duration"], :positive?
    refute check_ins[1].key?("monitor_config")
    feedback = @ingest.requests("/v1/feedback").first[:body]

    assert_equal ["The refund was wrong", -1.0, "4bf92f3577b34da6a3ce929d0e0e4736", "api", "shop@1.2.0"],
                 feedback.values_at("message", "score", "trace_id", "source", "release")
  end

  def test_retries_and_honours_rate_limits
    @ingest.answer = lambda do |n, _path|
      case n
      when 0 then [503, {}] # retried
      when 1 then [200, { "Fixwire-Rate-Limits" => "3600:error" }]
      else [200, {}]
      end
    end
    @ingest.init
    Fixwire.capture_message("first")

    assert Fixwire.flush(5)
    assert_equal 2, @ingest.requests("/v1/logs").size
    Fixwire.capture_message("dropped") # errors are paused for an hour; feedback isn't
    Fixwire.capture_feedback(score: 1)
    Fixwire.flush

    assert_equal 2, @ingest.requests("/v1/logs").size
    assert_equal 1, @ingest.requests("/v1/feedback").size
  end

  def test_budgets_crash_loops
    @ingest.init(error_budget: { per_issue_burst: 3 })
    sent = 20.times.count { |i| Fixwire.capture_message("order #{1000 + i} failed") }

    assert_equal 3, sent
    refute_nil Fixwire.capture_message("another issue")
    probe = Fixwire::Event.new(message: "order 1 failed")
    Fixwire.client.budget.age(Fixwire::Budget.issue_of(probe), 60)

    refute_nil Fixwire.capture_message("order 2000 failed")
    Fixwire.flush

    assert_equal 17, attrs(@ingest.log_records.last)["fixwire.suppressed"]
    m1 = Fixwire::Event.new(message: "user ada@example.com: 3 retries")
    m2 = Fixwire::Event.new(message: "user bob@example.org: 12 retries")

    assert_equal Fixwire::Budget.issue_of(m1), Fixwire::Budget.issue_of(m2)
    assert_equal "cbf29ce484222325", Fixwire::Budget.fnv1a("")
    assert_equal "af63dc4c8601ec8c", Fixwire::Budget.fnv1a("a")
  end

  def test_never_raises_into_the_app
    @ingest.answer = ->(_n, _path) { raise IOError, "the network is gone" }
    @ingest.init(release: "shop@1.0.0")

    refute_nil Fixwire.capture_message("a fine one")
    refute Fixwire.flush(5), "reported, not raised"
    assert_equal "done", Fixwire.with_monitor("nightly") { "done" }
  end

  def test_threads_keep_their_own_scope
    @ingest.init
    Fixwire.set_tag("app", "shop")
    seen = Array.new(4) do |i|
      Thread.new do
        Fixwire.set_tag("worker", i.to_s)
        Thread.pass
        Fixwire.hub.scope.tags.dup
      end
    end.map(&:value)

    assert_equal 4.times.map { |i| { "app" => "shop", "worker" => i.to_s } }, seen, "inherited, then their own"
    assert_equal({ "app" => "shop" }, Fixwire.hub.scope.tags, "the parent's is untouched")
  end

  def test_leaves_out_identifying_data_without_send_default_pii
    @ingest.init
    Fixwire.configure_scope do |scope|
      scope.request = Fixwire::Request.new(http_method: "GET", url: "https://shop.test/", client_address: "203.0.113.9",
                                           headers: { "authorization" => "Bearer x", "accept" => "*/*", "forwarded" => "for=203.0.113.9",
                                                      "cf-connecting-ip" => "203.0.113.9", "true-client-ip" => "203.0.113.9" })
      scope.set_user(id: "u-1", ip_address: "203.0.113.9")
    end
    Fixwire.capture_message("x")
    Fixwire.flush
    a = attrs(@ingest.log_records.first)

    refute a.key?("http.request.header.authorization")
    assert_empty(a.keys.grep(/forwarded|ip\z/), "proxies' and CDNs' headers with the user's IP")
    refute a.key?("client.address")
    assert_equal "*/*", a["http.request.header.accept"]
    assert_equal "Bearer x", Fixwire.hub.scope.request.headers["authorization"], "the scope's request stays whole"
  end

  private

  def with_env(values)
    saved = values.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end
