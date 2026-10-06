# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "json"
require "socket"
require "rbconfig"
require "tmpdir"
require_relative "../../test/support/http_server"

# Runs each example as it runs for real (Puma, the CLI) against a fake Fixwire, and checks what it
# receives, so the examples the docs show keep working.
class ExamplesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @ingest = TestHTTPServer.new
    @env = { "FIXWIRE_DSN" => "http://examplekey@127.0.0.1:#{@ingest.port}" }
  end

  def teardown
    @inventory&.stop
    @ingest.stop
  end

  def test_shop_api
    @inventory = TestHTTPServer.new { [201, {}, '{"held":1}'] }
    port = free_port
    log = "#{Dir.tmpdir}/fixwire-shop-api-#{port}.log"
    env = @env.merge("INVENTORY_URL" => @inventory.url)
    pid = start_server(env, "shop-api/config.ru", port, chdir: ROOT, %i[out err] => log)
    wait_for(port)
    base = "http://127.0.0.1:#{port}"

    assert_equal 200, http(:get, "#{base}/products/sku_1")
    assert_equal 404, http(:get, "#{base}/products/nope")
    assert_equal 201, http(:post, "#{base}/orders", '{"sku":"sku_1","card":"4242424242424242"}', "X-User-Id" => "user-1")
    assert_equal 402, http(:post, "#{base}/orders", '{"sku":"sku_2","card":"4000000000000002"}', "X-User-Id" => "user-2")
    assert_equal 500, http(:get, "#{base}/admin/report")
    stop_server(pid) # Puma stops; Fixwire sends what is left
    requests = @ingest.received(3)

    events = events(requests)

    assert_equal %w[RuntimeError ZeroDivisionError], events.keys, "not the 404\n#{File.read(log)}"
    declined = events["RuntimeError"]

    assert_equal(%w[RuntimeError PaymentDeclined], declined["fixwire.exceptions"].map { |x| x["type"] })
    assert_equal ["POST /orders", "user-2", { "sku" => "sku_2" }], declined.values_at("fixwire.transaction", "user.id", "fixwire.tags")
    assert_equal "sku_2", declined["fixwire.contexts"]["order"]["sku"]
    assert_equal %w[log http], declined["fixwire.breadcrumbs"].map { |b| b["category"] }, "the log line, the call to the inventory service"
    refute_includes requests.to_s, "4000000000000002", "the card stays in the app"

    crash = events["ZeroDivisionError"]

    assert_equal ["rack", false, "GET /admin/report"],
                 [crash["fixwire.exceptions"][0]["mechanism"]["type"], crash["fixwire.handled"], crash["fixwire.transaction"]]
    # The newest of the app's frames (Integer#/, written in C, is not the app's on Ruby 3.4).
    assert_equal "shop-api/app.rb", crash["fixwire.exceptions"][0]["frames"].reverse.find { |f| f["in_app"] }["file"]

    spans = spans(requests)
    product = spans.find { |s| s["name"] == "GET /products/:id" && status(s) == 200 }

    assert_equal product["spanId"], spans.find { |s| s["name"] == "SELECT products" && s["traceId"] == product["traceId"] }["parentSpanId"]
    order = spans.find { |s| s["name"] == "POST /orders" && s["traceId"] == declined["traceId"] }
    call = spans.find { |s| s["name"] == "POST #{@inventory.url}/reservations" && s["traceId"] == declined["traceId"] }

    assert_equal order["spanId"], call["parentSpanId"]
    assert_includes @inventory.received(2).map { |r| r[:headers]["traceparent"] }, "00-#{declined["traceId"]}-#{call["spanId"]}-01",
                    "the inventory service continues the trace"
    sessions = requests.select { |r| r[:path] == "/v1/sessions" }.flat_map { |r| JSON.parse(r[:body])["aggregates"] }

    assert_equal([3, 1, 1], %w[exited errored crashed].map { |k| sessions.sum { |a| a[k] } })
  end

  def test_nightly_report
    out = IO.popen(@env, ["bundle", "exec", "ruby", "nightly-report/report.rb"], chdir: ROOT, err: %i[child out], &:read)

    assert_equal 1, $?.exitstatus # rubocop:disable Style/SpecialGlobalVars
    assert_includes out, "acme: 2 invoices, 20.00 EUR"
    assert_includes out, "initech: 1 invoices, 43.00 EUR"
    requests = @ingest.received(4)

    check_ins = requests.select { |r| r[:path] == "/v1/check-ins/nightly-report" }.map { |r| JSON.parse(r[:body]) }

    assert_equal(%w[in_progress error], check_ins.map { |c| c["status"] })
    assert_equal({ "schedule" => { "type" => "crontab", "value" => "0 3 * * *" }, "checkin_margin" => 10, "max_runtime" => 30,
                   "timezone" => "Europe/Berlin" }, check_ins[0]["monitor_config"])
    assert_equal check_ins[0]["check_in_id"], check_ins[1]["check_in_id"]

    events = events(requests)
    failure = events["RuntimeError"]

    assert_equal(%w[RuntimeError NoInvoices], failure["fixwire.exceptions"].map { |x| x["type"] })
    assert_equal ["building the report for globex", { "account" => "globex" }], failure.values_at("exception.message", "fixwire.tags")
    summary = events["fixwire.message"]

    refute summary.key?("fixwire.tags"), "each account had its own scope"
    spans = spans(requests)
    root = spans.find { |s| s["name"] == "nightly-report" }

    assert_equal([root["spanId"]] * 3, %w[acme globex initech].map { |a| spans.find { |s| s["name"] == "report #{a}" }["parentSpanId"] })
    assert_equal root["traceId"], failure["traceId"]
  end

  private

  # Starts Puma with the app so the system can stop it: one process (Ruby loads Bundler and runs
  # Puma itself; bundle exec hands over to a second process on Windows), with Puma's control
  # server for Windows.
  def start_server(env, app, port, **)
    @control = free_port
    puma = [RbConfig.ruby, "-rbundler/setup", "-e", "load Gem.bin_path('puma', 'puma')", "--", app, "-b", "tcp://127.0.0.1:#{port}",
            "--control-url", "tcp://127.0.0.1:#{@control}", "--control-token", "examples"]
    spawn(env, *puma, **)
  end

  # Stops it as the system stops a program: SIGTERM; on Windows, which has no signal for that,
  # through Puma's control server, as `pumactl stop` does.
  def stop_server(pid)
    if Gem.win_platform?
      Net::HTTP.get(URI("http://127.0.0.1:#{@control}/stop?token=examples"))
    else
      Process.kill(:TERM, pid)
    end
    Process.wait(pid)
  end

  def events(requests)
    requests.select { |r| r[:path] == "/v1/logs" }.each_with_object({}) do |r, out|
      JSON.parse(r[:body])["resourceLogs"].each do |rl|
        rl["scopeLogs"].each do |sl|
          sl["logRecords"].each do |rec|
            a = kv(rec["attributes"]).merge("traceId" => rec["traceId"])
            out[a["exception.type"] || rec["eventName"]] = a
          end
        end
      end
    end
  end

  def spans(requests)
    requests.select { |r| r[:path] == "/v1/traces" }.flat_map do |r|
      JSON.parse(r[:body])["resourceSpans"].flat_map { |rs| rs["scopeSpans"].flat_map { |ss| ss["spans"] } }
    end
  end

  def status(span) = kv(span["attributes"])["http.response.status_code"]
  def kv(list) = (list || []).to_h { |a| [a["key"], value(a["value"])] }

  def value(val)
    return val["stringValue"] if val.key?("stringValue")
    return val["intValue"].to_i if val.key?("intValue")
    return val["boolValue"] if val.key?("boolValue")
    return val["arrayValue"]["values"].map { |x| value(x) } if val.key?("arrayValue")
    return kv(val["kvlistValue"]["values"]) if val.key?("kvlistValue")

    val["doubleValue"]
  end

  def http(method, url, body = nil, headers = {})
    uri = URI(url)
    request = method == :post ? Net::HTTP::Post.new(uri, headers.merge("Content-Type" => "application/json")) : Net::HTTP::Get.new(uri, headers)
    request.body = body if body
    Net::HTTP.start(uri.host, uri.port, read_timeout: 15) { |h| h.request(request) }.code.to_i
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def wait_for(port)
    100.times do
      TCPSocket.new("127.0.0.1", port).close
      return
    rescue Errno::ECONNREFUSED
      sleep 0.1
    end

    flunk "the app did not start on #{port}"
  end
end
