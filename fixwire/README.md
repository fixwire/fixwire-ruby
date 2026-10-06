# Fixwire for Ruby

The Fixwire SDK for Ruby 3.2+: errors with their causes, traces, release
health, cron monitors and feedback. It has no runtime dependencies.

```ruby
# Gemfile
gem "fixwire"
```

```ruby
Fixwire.init(
  dsn: "https://fw_pk_live_…@ingest.eu.fixwire.io", # or FIXWIRE_DSN
  release: "shop@1.4.0",                            # or FIXWIRE_RELEASE
  traces_sample_rate: 0.2
)
```

Without a DSN (and without `FIXWIRE_DSN`) the SDK does nothing. Rails apps
install [`fixwire-rails`](../fixwire-rails), which sets everything up.

`init` also reports the exception that ends the process (not `exit` or
Ctrl-C) as a crash, turns `Logger` records into breadcrumbs and traces
`Net::HTTP` requests. Sending happens on a background thread, so capturing
never waits. At exit, the SDK sends what is left, waiting up to
`shutdown_timeout`. A forked worker (Puma, Unicorn) starts its own sender.

**What's different**
- Secrets and personal data are masked on the device, with the same rules
  as the Fixwire server (`redact: false` turns it off).
- A crash loop costs a few events and a count, not your quota
  (`error_budget`).
- Sending honours rate limits, pausing only the kind of data a limit names.
- It speaks the Fixwire protocol: errors, messages and spans travel as
  OpenTelemetry's OTLP/HTTP (JSON), with structured stack traces,
  breadcrumbs and redaction on top.

## Errors

```ruby
begin
  payments.charge(order)
rescue PaymentError => e
  Fixwire.capture_exception(e)
end

Fixwire.set_user(id: "user-1")
Fixwire.set_tag("plan", "team")
Fixwire.set_context("order", { id: order.id, items: 3 })
Fixwire.add_breadcrumb(category: "cart", message: "checkout started")
Fixwire.capture_message("disk usage above 90%", level: :warning)
```

An exception is sent with its causes (`Exception#cause`: what was being
rescued when it was raised) and their stacks, with the source lines around
your frames. Files are named
relative to your project (`app/models/cart.rb`), gems by name and version.
Frames of gems and of Ruby itself are marked as not yours
(`in_app_include` and `in_app_exclude` adjust it).

`Fixwire.with_scope` gives a piece of work its own copy of the scope. Each
thread and fiber starts with a copy of the scope of the one that started it,
so concurrent requests and jobs keep their own.

```ruby
Fixwire.with_scope do |scope|
  scope.set_tag("account", account)
  build_report(account)
end
```

## Rack, Sidekiq and HTTP clients

```ruby
# config.ru (Sinatra, Roda, Hanami, plain Rack)
use Fixwire::Rack::Middleware
```

Each request gets its own scope and, with tracing on, is a server span
named after its route that continues the caller's trace. An exception
that escapes the app, or that the framework turned into a 500, is a crash.
The route comes from Sinatra (`GET /orders/:id`) or from
`env["fixwire.route"]`.

```ruby
require "fixwire/sidekiq" # after Fixwire.init
```

A job carries the trace of the code that pushed it. Running it is a span
that continues that trace, in a scope of its own, and a job that raises is
a crash, with the job.

`Net::HTTP` requests (and the clients built on it) are client spans and
breadcrumbs. Trace headers go only to `trace_propagation_targets`. Other
clients can use `Fixwire::OutgoingRequest.start(hub, method, url) { |name, value| … }`,
then `finish(status)` or `fail(error)`.

## Tracing

```ruby
rows = Fixwire.trace("SELECT carts", op: "db.query") { db.query(sql) }

span = Fixwire.start_span("export", op: "task")
# …
span.finish
```

A span without a parent is sent with the spans under it when it finishes.
`Fixwire.continue_trace(traceparent, tracestate, baggage, "GET /items")`
continues a caller's trace; its sampling decision holds.

## Cron jobs and feedback

```ruby
Fixwire.with_monitor("nightly-report", Fixwire::MonitorConfig.crontab("0 3 * * *", timezone: "Europe/Berlin")) do
  build_reports
end

Fixwire.capture_feedback(message: "Refunded the wrong order", score: -1, trace_id: run_trace_id)
```

A negative score opens a `user_feedback` issue for the agent run.

## Options

| Option | Default | |
|---|---|---|
| `dsn` | `FIXWIRE_DSN` | Where to send; nothing is sent without one |
| `release`, `environment` | `FIXWIRE_RELEASE`; `FIXWIRE_ENVIRONMENT`, `RAILS_ENV`, `RACK_ENV`, `production` | Release health needs a release |
| `service_name` | `OTEL_SERVICE_NAME`, else `shop` of `shop@1.4.0` | |
| `sample_rate` | 1 | Share of errors sent |
| `traces_sample_rate` | 0 | Share of new traces kept |
| `trace_propagation_targets` | none | URLs that receive trace headers |
| `before_send`, `before_breadcrumb` | | Change or drop events and breadcrumbs |
| `send_default_pii` | off | Send the user's IP address and identifying headers |
| `redact`, `sensitive_keys` | on, the server's keys | On-device masking |
| `error_budget` | 10 per issue, then 1 a minute; 600 a minute | |
| `auto_session_tracking` | on | A session per request, for release health (needs a release) |
| `capture_uncaught` | on | Report the exception that ends the process |
| `breadcrumbs_logger`, `trace_net_http` | on | `Logger` breadcrumbs, `Net::HTTP` spans |
| `project_root` | Bundler's root | Files are named relative to it |
| `in_app_include`, `in_app_exclude` | | Module prefixes that are, or are not, your code |
| `context_lines` | 5 | Source lines around each of your frames |
| `max_breadcrumbs`, `max_queue` | 100, 1000 | |
| `timeout`, `shutdown_timeout` | 5 s, 2 s | Of a request to Fixwire; of the exit's sending |
| `debug` | `FIXWIRE_DEBUG` | Log what the SDK does and drops to stderr |

An option that doesn't exist is an error, so a typo doesn't go unnoticed.

## Examples

[examples](examples) holds real apps, run by their tests against a fake
ingest: a Sinatra API ([shop-api](examples/shop-api)) and a cron job
([nightly-report](examples/nightly-report)).

## Building

```sh
bundle install
bundle exec rake test && bundle exec rubocop
(cd examples && bundle install && bundle exec ruby test/examples_test.rb)
```

## License

MIT.
