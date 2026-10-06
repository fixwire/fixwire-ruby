# frozen_string_literal: true

require_relative "test_helper"
require "sidekiq"
require "sidekiq/testing"
require "fixwire/sidekiq"

class ReserveStockJob
  include Sidekiq::Job

  def perform(sku) = Fixwire.add_breadcrumb(category: "stock", message: "reserved #{sku}")
end

class SendInvoiceJob
  include Sidekiq::Job

  sidekiq_options queue: "mail", retry: 3

  def perform(order) = raise(IOError, "the mail server refused #{order}")
end

# Sidekiq's inline testing mode runs the client and server middleware chains as a real push and
# run would, without Redis.
class SidekiqTest < Minitest::Test
  include FixwireTestCase

  def setup
    super
    Sidekiq::Testing.inline!
    Sidekiq::Testing.server_middleware { |chain| chain.add(Fixwire::Sidekiq::ServerMiddleware) }
  end

  def teardown
    Sidekiq::Testing.server_middleware(&:clear)
    Sidekiq::Testing.disable!
    super
  end

  def test_jobs_continue_the_trace_that_pushed_them
    @ingest.init(traces_sample_rate: 1.0)
    Fixwire.trace("POST /checkout", op: "http.server") { ReserveStockJob.perform_async("sku_1") }
    Fixwire.flush
    root = @ingest.spans.find { |s| s["name"] == "POST /checkout" }
    job = @ingest.spans.find { |s| s["name"] == "ReserveStockJob" }

    assert_equal [root["traceId"], root["spanId"]], job.values_at("traceId", "parentSpanId")
    assert_equal %w[queue.process sidekiq default], attrs(job).values_at("fixwire.op", "messaging.system", "messaging.destination.name")
    assert_empty Fixwire.hub.scope.breadcrumbs, "the job's breadcrumbs stayed in its scope"
  end

  def test_reports_failing_jobs_with_the_job
    @ingest.init(traces_sample_rate: 1.0)
    assert_raises(IOError) { SendInvoiceJob.perform_async("ord_7") }
    Fixwire.flush
    records = @ingest.log_records

    assert_equal 1, records.size
    a = attrs(records[0])

    assert_equal ["the mail server refused ord_7", "sidekiq", false, "SendInvoiceJob"],
                 [a["exception.message"], a["fixwire.exceptions"][0]["mechanism"]["type"], a["fixwire.handled"], a["fixwire.transaction"]]
    assert_equal({ "queue" => "mail", "sidekiq.retry" => "yes" }, a["fixwire.tags"])
    assert_equal "SendInvoiceJob", a["fixwire.contexts"]["job"]["class"]
    assert_equal 2, @ingest.spans.find { |s| s["name"] == "SendInvoiceJob" }["status"]["code"]
    assert_nil Fixwire.hub.scope.transaction, "the job's scope ended"
  end
end
