# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# What hostile or outsized input can't do: hang the app, sink a batch, leak past redaction or
# travel on to other services.
class LimitsTest < Minitest::Test
  include FixwireTestCase

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
    @ingest.init(traces_sample_rate: 1.0)
    Fixwire.capture_message("fine")
    Fixwire.capture_message("x" * 1_100_000)
    10.times { |i| Fixwire.add_breadcrumb(category: "import", message: "#{i} #{"y" * 120_000}") }
    Fixwire.capture_message("with heavy breadcrumbs")
    Fixwire.trace("import") do
      12.times { |i| Fixwire.start_span("chunk #{i}", attributes: { "data" => "z" * 500_000 }).finish }
    end

    refute Fixwire.flush(10), "the record over 1 MB was dropped"
    records = @ingest.log_records

    assert_equal(["fine", "with heavy breadcrumbs"], records.map { |r| FakeIngest.value(r["body"]) })
    refute attrs(records.last).key?("fixwire.breadcrumbs"), "sent without its breadcrumbs"
    traces = @ingest.requests("/v1/traces")

    assert_equal 13, @ingest.spans.size
    assert_operator traces.size, :>=, 2
    assert(traces.all? { |r| JSON.generate(r[:body]).bytesize < 5_100_000 })
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
  end

  def test_clamps_what_rate_limits_ask
    @ingest.answer = ->(_n, _path) { [200, { "Fixwire-Rate-Limits" => "#{"9" * 40}:error;whatever" }] }
    @ingest.init
    Fixwire.capture_message("first")
    Fixwire.flush
    paused = Fixwire.client.instance_variable_get(:@worker).instance_variable_get(:@paused)

    assert_equal ["error"], paused.keys
    assert_operator paused["error"] - now, :<=, 86_400
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
end
