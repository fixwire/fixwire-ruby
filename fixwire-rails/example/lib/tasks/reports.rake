# frozen_string_literal: true

namespace :reports do
  desc "Send the nightly reports (cron: 0 3 * * *)"
  task send: :environment do
    schedule = Fixwire::MonitorConfig.crontab("0 3 * * *", checkin_margin: 10, timezone: "Europe/Berlin")
    # Check-ins around the run: Fixwire notices a night it doesn't run, or fails.
    Fixwire.with_monitor("nightly-report", schedule) do
      { "acme" => [1200, 800], "globex" => [], "initech" => [4300] }.each do |account, invoices|
        raise "building the report for #{account}: no invoices" if invoices.empty?

        puts format("%<account>s: %<total>.2f EUR", account: account, total: invoices.sum / 100.0)
      end
    end
  end
end
