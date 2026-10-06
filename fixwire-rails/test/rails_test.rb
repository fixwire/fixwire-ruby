# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
core = File.expand_path("../../fixwire", __dir__)
$LOAD_PATH.unshift(File.join(core, "lib"))

ENV["DATABASE_URL"] = "sqlite3::memory:"
ENV["RAILS_ENV"] = "production"
require "rails"
require "action_controller/railtie"
require "active_record/railtie"
require "active_job/railtie"
require "fixwire/rails"
require "minitest/autorun"
require "rack/mock"
require "zlib"

# A fake Fixwire behind the SDK's transport.
class Ingest
  attr_reader :received

  def initialize = @received = []

  def send_request(url, body, _headers)
    @received << { path: URI.decode_www_form_component(URI(url).path), body: JSON.parse(Zlib.gunzip(body)) }
    [200, {}]
  end

  def events = logs.map { |r| kv(r["attributes"]).merge("traceId" => r["traceId"], "spanId" => r["spanId"]) }

  def logs
    @received.select { |r| r[:path] == "/v1/logs" }.flat_map { |r| r[:body]["resourceLogs"][0]["scopeLogs"][0]["logRecords"] }
  end

  def spans
    @received.select { |r| r[:path] == "/v1/traces" }.flat_map { |r| r[:body]["resourceSpans"][0]["scopeSpans"][0]["spans"] }
  end

  def span(name) = spans.find { |s| s["name"] == name }
  def resource = kv(@received.first[:body].values.first[0]["resource"]["attributes"])
  def kv(list) = (list || []).to_h { |a| [a["key"], value(a["value"])] }

  def value(v)
    return v["stringValue"] if v.key?("stringValue")
    return v["intValue"].to_i if v.key?("intValue")
    return v["boolValue"] if v.key?("boolValue")
    return v["arrayValue"]["values"].map { |x| value(x) } if v.key?("arrayValue")
    return kv(v["kvlistValue"]["values"]) if v.key?("kvlistValue")

    v["doubleValue"]
  end
end

INGEST = Ingest.new

class Current < ActiveSupport::CurrentAttributes
  attribute :user
end

AppUser = Struct.new(:id, :email)

class ShopApp < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.logger = Logger.new(StringIO.new)
  config.secret_key_base = "test" * 16
  config.hosts.clear
  config.consider_all_requests_local = false
  config.action_dispatch.show_exceptions = :all
  config.active_job.queue_adapter = :inline
  initializer "shop.fixwire", after: "fixwire.defaults" do
    Fixwire.init(dsn: "http://publickey@ingest.test", transport: INGEST, release: "shop@1.0.0", traces_sample_rate: 1.0,
                 trace_propagation_targets: ["inventory.test"])
  end
end

class ReserveStockJob < ActiveJob::Base
  def perform(sku) = Rails.logger.info("reserved #{sku}")
end

class SendInvoiceJob < ActiveJob::Base
  queue_as :mail
  def perform(order) = raise(IOError, "the mail server refused #{order}")
end

class OrdersController < ActionController::Base
  before_action { Current.user = AppUser.new(42, "ada@example.com") if request.headers["X-User"] }

  def show
    ActiveRecord::Base.connection.select_all("select 1 as id")
    Rails.logger.info("order loaded")
    raise "order #{params[:id]} has no lines"
  end

  def missing = raise(ActiveRecord::RecordNotFound)

  def checkout
    ReserveStockJob.perform_later("sku_1")
    render json: { ok: true }
  end

  def handled
    Rails.error.handle { raise ArgumentError, "coupon expired" }
    render plain: "ok"
  end
end

ShopApp.initialize!
ShopApp.routes.draw do
  get "/orders/:id", to: "orders#show"
  get "/missing", to: "orders#missing"
  post "/checkout", to: "orders#checkout"
  get "/handled", to: "orders#handled"
end

class RailsTest < Minitest::Test
  def setup
    INGEST.received.clear
  end

  def request(method, path, headers = {})
    response = Rack::MockRequest.new(ShopApp).request(method, path, headers)
    Fixwire.flush
    response
  end

  def test_reports_what_rails_reports_with_the_request
    response = request("GET", "/orders/7", "HTTP_TRACEPARENT" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "HTTP_X_USER" => "1")

    assert_equal 500, response.status
    assert_equal 1, INGEST.events.size
    e = INGEST.events.first

    assert_equal ["RuntimeError", "order 7 has no lines", false, "rails"],
                 [e["exception.type"], e["exception.message"], e["fixwire.handled"], e["fixwire.exceptions"][0]["mechanism"]["type"]]
    assert_equal ["GET /orders/:id", "/orders/:id", "42"], e.values_at("fixwire.transaction", "http.route", "user.id")
    refute e.key?("user.email"), "without send_default_pii"
    crumbs = e["fixwire.breadcrumbs"]

    assert_includes crumbs.map { |c| c["message"] }, "select 1 as id"
    assert_includes crumbs.map { |c| c["message"] }, "order loaded"
    top = e["fixwire.exceptions"][0]["frames"].last

    assert_equal ["show", "rails_test.rb", true], top.values_at("function", "file", "in_app"), "relative to Rails.root"
    sdk = e["fixwire.exceptions"][0]["frames"].select { |f| f["module"].to_s.start_with?("Fixwire") || f["function"] == "with_scope" }

    assert(sdk.all? { |f| !f["in_app"] && !f["file"].start_with?("/") }, "the SDK's frames are its own, and no machine path goes out")
    assert_equal "OrdersController", top["module"] if RUBY_VERSION >= "3.4"

    span = INGEST.span("GET /orders/:id")

    assert_equal ["4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7", 2], span.values_at("traceId", "parentSpanId", "kind")
    assert_equal 500, INGEST.kv(span["attributes"])["http.response.status_code"]
    assert_equal span["spanId"], e["spanId"]
    assert_equal span["spanId"], INGEST.span("select 1 as id")["parentSpanId"]
    assert_equal %w[production shop], INGEST.resource.values_at("deployment.environment.name", "service.name")
  end

  def test_leaves_out_what_rails_does_not_report
    assert_equal 404, request("GET", "/missing").status
    assert_equal 404, request("GET", "/no-such-route").status
    assert_empty INGEST.events
    assert_equal 404, INGEST.kv(INGEST.span("GET /missing")["attributes"])["http.response.status_code"]
  end

  def test_reports_handled_errors_as_handled
    assert_equal 200, request("GET", "/handled").status
    e = INGEST.events.first

    assert_equal ["coupon expired", nil, "GET /handled"], e.values_at("exception.message", "fixwire.handled", "fixwire.transaction")
    assert_equal 13, INGEST.logs.first["severityNumber"], "Rails reports a handled error as a warning"
  end

  def test_jobs_continue_the_trace_that_enqueued_them
    assert_equal 200, request("POST", "/checkout").status
    root = INGEST.span("POST /checkout")
    job = INGEST.span("ReserveStockJob")

    assert_equal [root["traceId"], root["spanId"]], job.values_at("traceId", "parentSpanId")
    assert_equal "queue.process", INGEST.kv(job["attributes"])["fixwire.op"]
  end

  def test_reports_failing_jobs_with_the_job
    assert_raises(IOError) { SendInvoiceJob.perform_later("ord_7") }
    Fixwire.flush

    assert_equal 1, INGEST.events.size
    e = INGEST.events.first

    assert_equal ["the mail server refused ord_7", "active_job", "SendInvoiceJob", { "queue" => "mail" }],
                 [e["exception.message"], e["fixwire.exceptions"][0]["mechanism"]["type"], e["fixwire.transaction"], e["fixwire.tags"]]
    assert_equal "SendInvoiceJob", e["fixwire.contexts"]["job"]["class"]
    assert_equal 2, INGEST.span("SendInvoiceJob")["status"]["code"]
  end

  def test_runs_jobs_whatever_their_payload_holds
    ActiveJob::Base.execute(ReserveStockJob.new("sku_2").serialize.merge("fixwire" => %w[not a trace]))
    Fixwire.flush

    assert_equal "queue.process", INGEST.kv(INGEST.span("ReserveStockJob")["attributes"])["fixwire.op"]
  end
end
