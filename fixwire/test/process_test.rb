# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/http_server"
require "open3"
require "rbconfig"

# What ends a Ruby process, and forking, in child processes that send over HTTP to a fake Fixwire.
class ProcessTest < Minitest::Test
  def setup
    @ingest = TestHTTPServer.new
  end

  def teardown
    @ingest.stop
  end

  def test_sends_the_exception_that_ends_the_process
    status, out = script("uncaught")

    assert_equal 1, status, "Ruby still exits as it would"
    assert_includes out, "amount 500 exceeds the limit (ArgumentError)"
    records = log_records(1)

    assert_equal 1, records.size
    a = FakeIngest.kv(records[0]["attributes"])

    assert_equal [21, false, "uncaught"],
                 [records[0]["severityNumber"], a["fixwire.handled"], a["fixwire.exceptions"][0]["mechanism"]["type"]]
    top = a["fixwire.exceptions"][0]["frames"].last

    assert_equal ["charge_card", "test/fixtures/script.rb", true], top.values_at("function", "file", "in_app")
    assert_equal(["started"], a["fixwire.breadcrumbs"].map { |b| b["message"] })
  end

  def test_leaves_out_exit_and_interrupt
    assert_equal 1, script("exit").first
    script("interrupt")

    assert_empty(@ingest.received(1, timeout: 1).select { |r| r[:path] == "/v1/logs" })
  end

  def test_sends_what_was_captured_at_exit
    assert_equal 0, script("message").first
    assert_equal "nightly report sent", FakeIngest.value(log_records(1)[0]["body"])
  end

  # A forked child restarts the sender it lost; on Windows, which has no fork, the child is a
  # process of its own. Either way both are sent.
  def test_keeps_sending_after_a_fork
    assert_equal 0, script("fork").first
    messages = log_records(2).map { |r| FakeIngest.value(r["body"]) }.sort

    assert_equal ["from the child", "from the parent"], messages
  end

  private

  def script(scenario)
    env = { "FIXWIRE_DSN" => "http://scriptkey@127.0.0.1:#{@ingest.port}" }
    out, status = Open3.capture2e(env, RbConfig.ruby, File.expand_path("fixtures/script.rb", __dir__), scenario)
    [status.exitstatus, out]
  end

  def log_records(count)
    @ingest.received(count).select { |r| r[:path] == "/v1/logs" }.flat_map do |r|
      JSON.parse(r[:body])["resourceLogs"].flat_map { |rl| rl["scopeLogs"].flat_map { |sl| sl["logRecords"] } }
    end
  end
end
