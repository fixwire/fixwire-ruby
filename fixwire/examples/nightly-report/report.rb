# frozen_string_literal: true

# A cron job reporting to Fixwire: check-ins to a monitor, one scope per account, carrying on after
# a failure, a summary warning and a trace for the run. What was captured is sent as the script
# exits.
#
#   FIXWIRE_DSN=https://<key>@<host> bundle exec ruby nightly-report/report.rb

require "fixwire"

class NoInvoices < StandardError; end

# The DSN comes from FIXWIRE_DSN; without it, Fixwire does nothing.
Fixwire.init(release: ENV.fetch("RELEASE", "nightly-report@1.0.0"), traces_sample_rate: 1.0)

def build_report(account, invoices)
  begin
    raise NoInvoices, "no invoices" if invoices.empty?
  rescue NoInvoices
    raise "building the report for #{account}" # its cause is the NoInvoices
  end
  format("%<account>s: %<count>d invoices, %<total>.2f EUR", account: account, count: invoices.size, total: invoices.sum / 100.0)
end

# Invoices per account, in cents; globex has none, which the report can't handle.
ACCOUNTS = { "acme" => [1200, 800], "globex" => [], "initech" => [4300] }.freeze

# The first check-in creates the monitor: every night at 3, Berlin time, with 10 minutes' margin and
# 30 minutes at most. Fixwire then also notices a night the job does not run.
schedule = Fixwire::MonitorConfig.crontab("0 3 * * *", checkin_margin: 10, max_runtime: 30, timezone: "Europe/Berlin")
run = Fixwire.capture_check_in("nightly-report", :in_progress, config: schedule)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

failed = Fixwire.trace("nightly-report", op: "task") do
  ACCOUNTS.count do |account, invoices|
    # A scope per account: its tag stays on its own events.
    Fixwire.with_scope do |scope|
      scope.set_tag("account", account)
      puts Fixwire.trace("report #{account}", op: "task") { build_report(account, invoices) }
      false
    rescue RuntimeError => e
      Fixwire.capture_exception(e) # and carry on with the next account
      true
    end
  end
end

Fixwire.capture_message("#{failed} of #{ACCOUNTS.size} reports failed", level: :warning) if failed.positive?
Fixwire.capture_check_in("nightly-report", failed.positive? ? :error : :ok, id: run,
                                                                            duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
exit(failed.positive? ? 1 : 0) # what was captured is sent at exit
