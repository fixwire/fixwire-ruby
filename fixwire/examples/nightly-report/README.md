# Nightly report (a cron job)

```sh
bundle install    # in examples/
FIXWIRE_DSN=https://<key>@<host> bundle exec ruby nightly-report/report.rb
```

The job builds a report per account. One account (`globex`) has no
invoices: the job reports that failure with the account as a tag, carries
on with the others, sends a summary warning and exits 1.

What arrives in Fixwire:

- **Check-ins** for the `nightly-report` monitor: `in_progress` when the
  run starts and `error` when it ends, with its duration. The first
  check-in creates the monitor (every night at 3, Berlin time, 10 minutes'
  margin, 30 minutes at most), so Fixwire also notices a night the job does
  not run at all.
- **The failure**, tagged `account: globex`, with the chain `building the
  report for globex` caused by `NoInvoices: no invoices`.
- **The summary warning**, without the account's tag: each account had its
  own scope (`Fixwire.with_scope`).
- **A trace for the run**, with a span per account; the failure is linked
  to it.

How it is wired, in `report.rb`:

```ruby
Fixwire.init(release: "nightly-report@1.0.0", traces_sample_rate: 1.0)

schedule = Fixwire::MonitorConfig.crontab("0 3 * * *", checkin_margin: 10, max_runtime: 30, timezone: "Europe/Berlin")
run = Fixwire.capture_check_in("nightly-report", :in_progress, config: schedule)
# … the reports …
Fixwire.capture_check_in("nightly-report", failed.positive? ? :error : :ok, id: run, duration: elapsed)
exit(failed.positive? ? 1 : 0) # what was captured is sent at exit
```

For a job that fails by raising, `Fixwire.with_monitor("nightly-report",
schedule) { … }` sends both check-ins around it.
