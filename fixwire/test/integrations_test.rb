# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/http_server"
require "rack"
require "rack/mock"
require "logger"

class IntegrationsTest < Minitest::Test
  include FixwireTestCase

  def teardown
    @service&.stop
    super
  end

  def test_rack_middleware_tracks_requests
    @ingest.init(traces_sample_rate: 1.0, release: "shop@1.0.0", auto_session_tracking: true)
    app = lambda do |env|
      case env["PATH_INFO"]
      when "/boom" then raise KeyError, "no stock"
      when %r{\A/orders/}
        env["fixwire.route"] = "/orders/:id"
        Fixwire.capture_message("in handler")
        [404, {}, ["no such order"]]
      else [200, {}, ["ok"]]
      end
    end
    stack = Fixwire::Rack::Middleware.new(app)
    response = Rack::MockRequest.new(stack).get("/orders/7?ref=ad", "HTTP_TRACEPARENT" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                                                                    "HTTP_AUTHORIZATION" => "Bearer secret", "HTTP_USER_AGENT" => "curl/8",
                                                                    "REMOTE_ADDR" => "203.0.113.9")

    assert_equal 404, response.status
    assert_raises(KeyError) { Rack::MockRequest.new(stack).post("/boom") }
    assert_nil Fixwire.hub.scope.request, "the request was on its own scope"
    Fixwire.flush
    records = @ingest.log_records
    message = attrs(records[0])

    assert_equal ["GET /orders/:id", "http://example.org/orders/7", "ref=ad", "/orders/:id", "curl/8"],
                 message.values_at("fixwire.transaction", "url.full", "url.query", "http.route", "user_agent.original")
    refute message.key?("http.request.header.authorization"), "without send_default_pii"
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", records[0]["traceId"]
    boom = attrs(records[1])

    assert_equal ["rack", false], [boom["fixwire.exceptions"][0]["mechanism"]["type"], boom["fixwire.handled"]]
    spans = @ingest.spans.to_h { |s| [s["name"], s] }

    assert_equal ["GET /orders/:id", "POST /boom"], spans.keys
    get = spans["GET /orders/:id"]

    assert_equal ["00f067aa0ba902b7", 2, 404, { "code" => 1 }],
                 [get["parentSpanId"], get["kind"], attrs(get)["http.response.status_code"], get["status"]]
    assert_equal 2, spans["POST /boom"]["status"]["code"]
    sessions = @ingest.requests("/v1/sessions").first[:body]["aggregates"]

    assert_equal [1, 1], [sessions.sum { |a| a["exited"] }, sessions.sum { |a| a["crashed"] }]
  end

  def test_rack_middleware_reports_what_a_framework_rescued_into_an_error_page
    @ingest.init
    app = lambda do |env|
      env["sinatra.error"] = ZeroDivisionError.new("divided by 0")
      env["sinatra.route"] = "GET /report"
      [500, {}, ["Internal Server Error"]]
    end
    Rack::MockRequest.new(Fixwire::Rack::Middleware.new(app)).get("/report")
    Fixwire.flush
    a = attrs(@ingest.log_records.first)

    assert_equal ["ZeroDivisionError", "GET /report"], a.values_at("exception.type", "fixwire.transaction")
  end

  def test_traces_net_http_requests
    @service = TestHTTPServer.new { |r| [r[:path].include?("down") ? 503 : 200, {}, "{}"] }
    @ingest.init(traces_sample_rate: 1.0, trace_net_http: true, trace_propagation_targets: [@service.url])
    Fixwire.trace("POST /checkout", op: "http.server") do
      Net::HTTP.get_response(URI("#{@service.url}/charges?card=4242"))
      Net::HTTP.get_response(URI("#{@service.url}/down"))
      Net::HTTP.start("127.0.0.1", @service.port) do |http|
        http.request(Net::HTTP::Get.new("/mine", "traceparent" => "mine"))
      end
    end
    Fixwire.capture_message("done")
    Fixwire.flush
    received = @service.received(3)
    root = @ingest.spans.find { |s| s["name"] == "POST /checkout" }
    charge = @ingest.spans.find { |s| s["name"] == "GET #{@service.url}/charges" }

    assert_match(/\A00-#{root["traceId"]}-#{charge["spanId"]}-01\z/o, received[0][:headers]["traceparent"])
    assert_equal "mine", received[2][:headers]["traceparent"], "the app's own trace header wins"
    assert_equal [root["spanId"], 3, 200], [charge["parentSpanId"], charge["kind"], attrs(charge)["http.response.status_code"]]
    down = @ingest.spans.find { |s| s["name"] == "GET #{@service.url}/down" }

    assert_equal 2, down["status"]["code"]
    crumbs = attrs(@ingest.log_records.first)["fixwire.breadcrumbs"]

    assert_equal([%w[GET charges 200], %w[GET down 503]], crumbs.first(2).map do |c|
      [c["data"]["method"], c["data"]["url"].split("/").last, c["data"]["status_code"].to_s]
    end)
    assert_equal(%w[info error], crumbs.first(2).map { |c| c["level"] })
  end

  def test_sends_its_own_requests_untraced
    ingest = TestHTTPServer.new
    Fixwire.init(dsn: "http://k@127.0.0.1:#{ingest.port}", traces_sample_rate: 1.0, trace_net_http: true,
                 breadcrumbs_logger: false, auto_session_tracking: false)
    Fixwire.trace("job") { Fixwire.capture_message("from a job") }

    assert Fixwire.flush
    paths = ingest.received(2).map { |r| r[:path] }.sort

    assert_equal ["/v1/logs", "/v1/traces"], paths, "no span or breadcrumb for sending them"
    ingest.stop
  end

  def test_turns_log_records_into_breadcrumbs
    @ingest.init(breadcrumbs_logger: true)
    log = Logger.new(StringIO.new) # Logger.new(File::NULL) writes, and formats, nothing
    log.debug("not kept")
    log.info("cart loaded")
    log.warn("payments") { "slow gateway" }
    log.level = :error
    log.warn("below the logger's level")
    Fixwire.capture_message("x")
    Fixwire.flush
    crumbs = attrs(@ingest.log_records.first)["fixwire.breadcrumbs"]

    assert_equal([["log", "cart loaded", "info"], ["payments", "slow gateway", "warning"]], crumbs.map do |c|
      c.values_at("category", "message", "level")
    end)
  end

  def test_logging_while_keeping_a_log_record_does_not_recurse
    log = Logger.new(StringIO.new)
    keep = lambda do |crumb|
      log.info("seen")
      log.info("seen again")
      crumb
    end
    @ingest.init(breadcrumbs_logger: true, before_breadcrumb: keep)
    log.info("cart loaded")
    Fixwire.capture_message("x")
    Fixwire.flush

    assert_equal(["cart loaded"], attrs(@ingest.log_records.first)["fixwire.breadcrumbs"].map { |c| c["message"] })
  end
end
