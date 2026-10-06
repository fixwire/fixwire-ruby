# Fixwire for Rails

Fixwire in a Rails 7.1+ app: the exceptions Rails reports, each request as
a trace named after its route, the signed-in user, Active Record queries,
Active Job jobs continuing the trace that enqueued them, rake tasks, and
release health. It builds on the [Ruby SDK](../fixwire), which comes with
it.

```ruby
# Gemfile
gem "fixwire-rails"
```

```sh
FIXWIRE_DSN=https://fw_pk_live_…@ingest.eu.fixwire.io
FIXWIRE_RELEASE=shop@1.4.0
```

That's all: with `FIXWIRE_DSN` in the environment, Fixwire starts with the
app, using Rails's environment and root. Without a DSN (development, your
test suite) it does nothing. To set more, start it yourself:

```ruby
# config/initializers/fixwire.rb
Fixwire.init(
  release: ENV["FIXWIRE_RELEASE"],
  traces_sample_rate: 0.2,
  trace_propagation_targets: [ENV["INVENTORY_URL"]]
)
```

## What it does

- **Exceptions Rails reports** (`Rails.error`) go to Fixwire with the
  request, the route (`GET /orders/:id`), the user, and the breadcrumbs
  that led to them: log lines, SQL queries (without their values), HTTP
  calls. That covers a request that Rails answers with a 500, a failing
  job, and what your code reports with `Rails.error.report` or
  `Rails.error.handle` (sent as handled). Exceptions Rails answers as client
  errors (404s, bad parameters) aren't sent. Each exception is sent once.
- **The signed-in user** comes from `Current.user` (Rails's authentication
  generator) or Warden (Devise), read only when an event or a session needs
  it. That is the id only, plus the email with `send_default_pii`.
  `Fixwire::Rails.user = ->(env) { … }` sets your own.
- **Each request** gets its own scope and, with tracing on, is a server span
  named after its route that continues the caller's trace, with its queries
  and HTTP calls under it.
- **Active Job**: a job carries the trace of the code that enqueued it.
  Performing it is a span that continues that trace, in a scope of its own
  (the queue as a tag, the job as context), and a job that raises is a
  crash, with the job.
- **Rake tasks**: an exception that ends one is a crash, named after the
  task.
- **Release health**: each request is a session, ended well, with an error,
  or crashed. The counts go out every minute.

Sidekiq jobs that don't go through Active Job: add
`require "fixwire/sidekiq"` to the initializer.

## Cron jobs

```ruby
# lib/tasks/reports.rake
task send_reports: :environment do
  Fixwire.with_monitor("nightly-report", Fixwire::MonitorConfig.crontab("0 3 * * *", timezone: "Europe/Berlin")) do
    Reports.send_all
  end
end
```

Each run sends a check-in when it starts and one when it ends, ok or
failed. The first creates the monitor, so Fixwire also notices a night the
task doesn't run.

## Example

[example](example) is a Rails app (an API, an Active Job job, a rake task)
whose test runs it with Puma and `rake` against a fake ingest.

## Building

```sh
bundle install
bundle exec rake test && bundle exec rubocop
(cd example && bundle install && bundle exec ruby test/example_test.rb)
```

## License

MIT.
