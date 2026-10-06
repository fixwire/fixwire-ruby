# frozen_string_literal: true

require "rbconfig"

require "minitest/autorun"
require "net/http"
require "json"
require "socket"
require "tmpdir"
require_relative "../../../fixwire/test/support/http_server"

# Runs the app as it runs for real (Puma in production, a rake task as cron runs it) against a fake
# Fixwire and a fake inventory service, and checks what Fixwire receives.
class ExampleTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @ingest = TestHTTPServer.new
    @inventory = TestHTTPServer.new { [201, {}, '{"held":1}'] }
    @env = { "FIXWIRE_DSN" => "http://examplekey@127.0.0.1:#{@ingest.port}", "INVENTORY_URL" => @inventory.url, "RAILS_ENV" => "production" }
  end

  def teardown
    @inventory.stop
    @ingest.stop
  end

  def test_the_api
    port = free_port
    log = "#{Dir.tmpdir}/fixwire-rails-example-#{port}.log"
    pid = start_server(@env, "config.ru", port, chdir: ROOT, %i[out err] => log)
    wait_for(port)
    base = "http://127.0.0.1:#{port}"

    assert_equal 200, http(:get, "#{base}/orders/7")
    assert_equal 400, http(:post, "#{base}/orders", "{}")
    assert_equal 201, http(:post, "#{base}/orders", '{"order":{"sku":"sku_1","card":"4242424242424242"}}', "X-User-Id" => "user-1")
    assert_equal 402, http(:post, "#{base}/orders", '{"order":{"sku":"sku_2","card":"4000000000000002"}}', "X-User-Id" => "user-2")
    assert_equal 500, http(:get, "#{base}/admin/report")
    reservations = @inventory.received(2) # the jobs ran
    stop_server(pid) # Puma stops; Fixwire sends what is left
    requests = @ingest.received(3)
    events = events(requests)

    assert_equal %w[RuntimeError ZeroDivisionError], events.keys.sort, "not the 400\n#{File.read(log)[-3000..]}"
    declined = events["RuntimeError"]

    assert_equal ["POST /orders", "user-2", nil], declined.values_at("fixwire.transaction", "user.id", "fixwire.handled")
    assert_equal "sku_2", declined["fixwire.contexts"]["order"]["sku"]
    assert_includes declined["fixwire.breadcrumbs"].map { |b| b["message"] }, "order received"
    crash = events["ZeroDivisionError"]

    assert_equal ["rails", false, "GET /admin/report"],
                 [crash["fixwire.exceptions"][0]["mechanism"]["type"], crash["fixwire.handled"], crash["fixwire.transaction"]]
    # The newest of the app's frames (Integer#/, written in C, is not the app's on Ruby 3.4).
    assert_equal "app/controllers/orders_controller.rb", crash["fixwire.exceptions"][0]["frames"].reverse.find { |f| f["in_app"] }["file"]

    spans = spans(requests)
    show = spans.find { |s| s["name"] == "GET /orders/:id" }

    assert(spans.any? { |s| s["parentSpanId"] == show["spanId"] && s["name"].start_with?("select 7 as id") }, "the query under the request")
    placed = spans.find { |s| s["name"] == "POST /orders" && status(s) == 201 }
    job = spans.find { |s| s["name"] == "ReserveStockJob" && s["traceId"] == placed["traceId"] }

    assert_equal placed["spanId"], job["parentSpanId"], "the job continues the order's trace"
    call = spans.find { |s| s["parentSpanId"] == job["spanId"] }

    assert_equal "POST #{@inventory.url}/reservations", call["name"]
    assert_includes reservations.map { |r| r[:headers]["traceparent"] }, "00-#{placed["traceId"]}-#{call["spanId"]}-01",
                    "the inventory service continues the trace"
  end

  def test_the_nightly_report_task
    out = IO.popen(@env, %w[bundle exec rake reports:send], chdir: ROOT, err: %i[child out], &:read)

    refute_predicate $?, :success? # rubocop:disable Style/SpecialGlobalVars
    assert_includes out, "acme: 20.00 EUR"
    requests = @ingest.received(3)
    check_ins = requests.select { |r| r[:path] == "/v1/check-ins/nightly-report" }.map { |r| JSON.parse(r[:body]) }

    assert_equal(%w[in_progress error], check_ins.map { |c| c["status"] })
    assert_equal "Europe/Berlin", check_ins[0]["monitor_config"]["timezone"]
    failure = events(requests)["RuntimeError"]

    assert_equal ["building the report for globex: no invoices", "rake", false, "rake reports:send"],
                 [failure["exception.message"], failure["fixwire.exceptions"][0]["mechanism"]["type"], failure["fixwire.handled"],
                  failure["fixwire.transaction"]]
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
    Net::HTTP.start(uri.host, uri.port, read_timeout: 30) { |h| h.request(request) }.code.to_i
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def wait_for(port)
    300.times do
      TCPSocket.new("127.0.0.1", port).close
      return
    rescue Errno::ECONNREFUSED
      sleep 0.1
    end

    flunk "the app did not start on #{port}"
  end
end
