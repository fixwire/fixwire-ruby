<div align="center">

_Bugs reach production. Fixwire finds them first: errors, traces, logs and
AI agent runs in one place, an AI debugger on every plan, and your data
kept in Europe._

[![Discord](https://img.shields.io/badge/Discord-join%20us-5865F2?logo=discord&logoColor=white)](https://fixwire.io/discord)
[![Slack](https://img.shields.io/badge/Slack-community-4A154B?logo=slack&logoColor=white)](https://fixwire.io/slack)
[![X](https://img.shields.io/badge/X-follow%20us-000000?logo=x&logoColor=white)](https://fixwire.io/x)
[![Release](https://img.shields.io/github/v/release/fixwire/fixwire-ruby?label=release)](https://github.com/fixwire/fixwire-ruby/releases)
[![Ruby](https://img.shields.io/badge/ruby-3.2%20%7C%203.3%20%7C%203.4%20%7C%204.0-blue?logo=ruby&logoColor=white)](https://github.com/fixwire/fixwire-ruby/blob/main/.github/workflows/ci.yml)
[![Rails](https://img.shields.io/badge/rails-7.1%20%7C%207.2%20%7C%208.0%20%7C%208.1-blue?logo=rubyonrails&logoColor=white)](https://github.com/fixwire/fixwire-ruby/blob/main/.github/workflows/ci.yml)
[![CI](https://github.com/fixwire/fixwire-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/fixwire/fixwire-ruby/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/fixwire/fixwire-ruby/blob/main/LICENSE)

<br/>

</div>

# Fixwire SDK for Ruby

Welcome to the official Ruby SDK for **[Fixwire](https://fixwire.io)**. It
captures errors with their causes, crashes, traces, release health, cron
monitors and user feedback from your Ruby and Rails apps.

This repository holds two gems:

| Gem | For |
| --- | --- |
| [`fixwire`](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire) | Any Ruby program, with no runtime dependencies: Rack apps (Sinatra, Hanami, Roda), `Net::HTTP`, `Logger`, Rake and Sidekiq |
| [`fixwire-rails`](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire-rails) | Rails apps: what Rails reports, route-named requests, the signed-in user, Active Record and Active Job. It brings `fixwire` along |

## 📦 Getting started

### Prerequisites

- A Fixwire account and project: sign up at
  [fixwire.io](https://fixwire.io).
- Ruby 3.2 or newer (tested on 3.2, 3.3, 3.4 and 4.0, on Linux, macOS and
  Windows).
- For `fixwire-rails`: Rails 7.1 or newer (tested on 7.1, 7.2, 8.0 and
  8.1). For the Sidekiq integration: Sidekiq 7 or newer.

### Installation

```sh
bundle add fixwire        # any Ruby app
bundle add fixwire-rails  # a Rails app
```

### Basic configuration

Call `Fixwire.init` once, when your app starts:

```ruby
require "fixwire"

Fixwire.init(
  dsn: "https://fw_pk_live_…@ingest.eu.fixwire.io", # or FIXWIRE_DSN
  release: "shop@1.4.0",                            # or FIXWIRE_RELEASE
  environment: "production",                        # or FIXWIRE_ENVIRONMENT, RAILS_ENV, RACK_ENV
  # send_default_pii: true, # also send users' IP addresses and identifying headers
  # redact: false,          # stop masking secrets and personal data on the device
  traces_sample_rate: 0.2   # keep a fifth of new traces
)
```

The DSN is your project's publishable key and the ingest host:
`https://<publishable key>@<host>`. Without the `dsn` option the SDK reads
`FIXWIRE_DSN`; without either it does nothing, so the same code runs in
tests and on your laptop. `init` also takes its options in a block
(`Fixwire.init { |c| c.release = "shop@1.4.0" }`), or both.

`init` never raises. An option that doesn't exist is reported on stderr and
ignored, so a typo doesn't go unnoticed and doesn't stop the app from
starting. A broken DSN is reported on stderr too, and the SDK stays off.

Once started, the SDK reports the exception that ends the process (not
`exit` or Ctrl-C) as a crash, turns `Logger` records into breadcrumbs and
traces `Net::HTTP` requests. Sending happens on a background thread, so
capturing never waits. At exit, the SDK sends what is left, waiting up to
`shutdown_timeout`. A forked worker (Puma, Unicorn) starts its own sender.

In a Rails app, `fixwire-rails` starts the SDK for you as soon as
`FIXWIRE_DSN` is set; see
[Rails](https://github.com/fixwire/fixwire-ruby#rails).

### Quick usage example

```ruby
Fixwire.capture_message("Hello Fixwire!") # a message event, with the scope's user, tags and breadcrumbs

begin
  payments.charge(order)
rescue PaymentError => e
  Fixwire.capture_exception(e) # an issue: the exception, its causes and their stacks
end
```

Add who and what the work is for, and what happened before an error:

```ruby
Fixwire.set_user(id: "user-1")
Fixwire.set_tag("plan", "team")
Fixwire.set_context("order", { id: order.id, items: 3 })
Fixwire.add_breadcrumb(category: "cart", message: "checkout started")
Fixwire.capture_message("disk usage above 90%", level: :warning)
```

## ✨ Why Fixwire

- **Secrets stay on the device.** Secrets and personal data are masked
  before anything is sent, with the same rules as the Fixwire server
  (`redact: false` turns it off).
- **A crash loop costs a few events and a count, not your quota.** Each
  issue sends a burst, then a few a minute; what is held back is counted
  (`error_budget`).
- **It never gets in your app's way.** `init` never raises, and capturing
  never waits: one background thread sends from a bounded queue, retries
  with backoff and honours rate limits, pausing only the kind of data a
  limit names. Memory and time stay bounded, and an exception in your own
  callbacks or objects (`before_send`, `to_s`) is caught, not passed to
  you.
- **OpenTelemetry-native.** It speaks the Fixwire protocol
  (OpenTelemetry's OTLP/HTTP plus a few small JSON endpoints): errors,
  messages and spans travel as OTLP/HTTP JSON, with structured stack
  traces, breadcrumbs and redaction on top.
- **Trace headers only where you allow.** Outgoing requests carry them
  only to your `trace_propagation_targets`; none by default.
- **Your data stays in Europe.** Fixwire is hosted in Europe.
- **No dependencies.** The `fixwire` gem needs nothing but Ruby's standard
  library.

## 🧩 Integrations

| Integration | What it does | How to use |
| --- | --- | --- |
| Rails | The exceptions Rails reports, each request as a trace named after its route, the signed-in user, Active Record queries, rake tasks and release health | `bundle add fixwire-rails` and set `FIXWIRE_DSN` |
| Active Job | A job continues the trace that enqueued it, in a scope of its own; a job that raises is a crash | Comes with `fixwire-rails` |
| Rack (Sinatra, Hanami, Roda) | A scope, a release-health session and (with tracing on) a server span per request, named after its route; exceptions that escape the app, or that the framework turned into a 500, are crashes | `use Fixwire::Rack::Middleware` |
| Sidekiq | A job continues the trace that pushed it, in a scope of its own; a job that raises is a crash, with the job | `require "fixwire/sidekiq"` after `Fixwire.init` |
| `Net::HTTP` | Requests (and the clients built on it) as client spans and breadcrumbs; trace headers to your `trace_propagation_targets` only | On by default (`trace_net_http`) |
| `Logger` | Records from `INFO` up become breadcrumbs | On by default (`breadcrumbs_logger`) |
| Rake | The exception that ends a task is a crash, named after the task | On when Rake is loaded |

### Errors and scopes

An exception is sent with its causes (`Exception#cause`: what was being
rescued when it was raised) and their stacks, with the source lines around
your frames. Files are named relative to your project
(`app/models/cart.rb`), gems by name and version. Frames of gems and of
Ruby itself are marked as not yours (`in_app_include` and
`in_app_exclude` adjust it).

`Fixwire.with_scope` gives a piece of work its own copy of the scope. Each
thread and fiber starts with a copy of the scope of the one that started
it, so concurrent requests and jobs keep their own.

```ruby
Fixwire.with_scope do |scope|
  scope.set_tag("account", account)
  build_report(account)
end
```

### Rails

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

- **Exceptions Rails reports** (`Rails.error`) go to Fixwire with the
  request, the route (`GET /orders/:id`), the user, and the breadcrumbs
  that led to them: log lines, SQL queries (without their values), HTTP
  calls. That covers a request that Rails answers with a 500, a failing
  job, and what your code reports with `Rails.error.report` or
  `Rails.error.handle` (sent as handled). Exceptions Rails answers as
  client errors (404s, bad parameters) aren't sent. Each exception is sent
  once.
- **The signed-in user** comes from `Current.user` (Rails's authentication
  generator) or Warden (Devise), read only when an event or a session
  needs it. That is the id only, plus the email with `send_default_pii`.
  `Fixwire::Rails.user = ->(env) { … }` sets your own.
- **Each request** gets its own scope and, with tracing on, is a server
  span named after its route that continues the caller's trace, with its
  queries and HTTP calls under it.
- **Active Job**: a job carries the trace of the code that enqueued it.
  Performing it is a span that continues that trace, in a scope of its own
  (the queue as a tag, the job as context), and a job that raises is a
  crash, with the job.
- **Rake tasks**: an exception that ends one is a crash, named after the
  task.
- **Release health**: each request is a session, ended well, with an
  error, or crashed. The counts go out every minute.

Sidekiq jobs that don't go through Active Job: add
`require "fixwire/sidekiq"` to the initializer.

### Rack apps

```ruby
# config.ru (Sinatra, Roda, Hanami, plain Rack)
use Fixwire::Rack::Middleware
```

Each request gets its own scope (handlers set things on it with
`Fixwire.set_user`, `Fixwire.set_tag` and the like) and is a
release-health session. With tracing on, it is a server span named after
its route that continues the caller's trace. An exception that escapes the
app, or that the framework turned into a 500, is a crash. The route comes
from Sinatra (`GET /orders/:id`) or from `env["fixwire.route"]`.

### Sidekiq

```ruby
require "fixwire/sidekiq" # after Fixwire.init
```

A job carries the trace of the code that pushed it. Running it is a span
that continues that trace, in a scope of its own (the queue as a tag, the
job as context), and a job that raises is a crash, with the job (whether
Sidekiq retries it is a tag).

### HTTP clients

`Net::HTTP` requests, and the clients built on it, are client spans and
breadcrumbs, and carry trace headers only to `trace_propagation_targets`.
Another client can do the same with `Fixwire::OutgoingRequest`:

```ruby
request = Fixwire::OutgoingRequest.start(Fixwire.hub, "GET", url) { |name, value| headers[name] = value }
response = my_client.get(url, headers)
request.finish(response.status) # or, when there was no answer: request.fail(error)
```

### Tracing

```ruby
rows = Fixwire.trace("SELECT carts", op: "db.query") { db.query(sql) }

span = Fixwire.start_span("export", op: "task")
# …
span.finish
```

`traces_sample_rate` sets the share of new traces kept. A span without a
parent in the process (a request, a job) is sent with the spans under it
when it finishes. An exception raised in `Fixwire.trace` marks the span
failed and goes on.
`Fixwire.continue_trace(traceparent, tracestate, baggage, "GET /items")`
continues a caller's trace; its sampling decision holds.

### Cron monitors

```ruby
schedule = Fixwire::MonitorConfig.crontab("0 3 * * *", checkin_margin: 10, max_runtime: 30, timezone: "Europe/Berlin")

Fixwire.with_monitor("nightly-report", schedule) do
  build_reports
end
```

Each run sends a check-in when it starts and one when it ends, ok or
failed (an exception goes on after it is reported). The first check-in
creates the monitor, so Fixwire also notices a night the job doesn't run.
`checkin_margin` and `max_runtime` are minutes;
`Fixwire::MonitorConfig.interval(6, "hour")` is a job that runs every six
hours. `Fixwire.capture_check_in(monitor, :in_progress)` and then
`:ok` or `:error` with the returned `id:` send check-ins by hand.

In a Rails app, wrap a rake task:

```ruby
# lib/tasks/reports.rake
task send_reports: :environment do
  Fixwire.with_monitor("nightly-report", Fixwire::MonitorConfig.crontab("0 3 * * *", timezone: "Europe/Berlin")) do
    Reports.send_all
  end
end
```

### Feedback

Rate an AI answer, or say what went wrong with a crash. A negative score
opens a `user_feedback` issue for the agent run:

```ruby
Fixwire.capture_feedback(message: "Refunded the wrong order", score: -1, trace_id: run_trace_id)
```

Feedback also takes `event_id:` (such as `Fixwire.last_event_id` after a
crash), `name:`, `email:`, `url:` and `source:`.

## ⚙️ Configuration

| Option | Default | What it does |
| --- | --- | --- |
| `dsn` | `FIXWIRE_DSN` | Where to send; nothing is sent without one |
| `release` | `FIXWIRE_RELEASE` | The app's version (`shop@1.4.0`, a commit SHA); release health needs one |
| `environment` | `FIXWIRE_ENVIRONMENT`, else `RAILS_ENV`, `RACK_ENV`, else `production` (Rails's environment in Rails) | Where the app runs |
| `server_name` | the host name | Names the machine |
| `service_name` | `OTEL_SERVICE_NAME`, else `shop` of `shop@1.4.0` | Names the service |
| `sample_rate` | 1 | Share of errors and messages sent |
| `traces_sample_rate` | 0 | Share of new traces kept; a trace continued from a caller follows its decision |
| `trace_propagation_targets` | none | Hosts, URL prefixes and regexps whose requests carry trace headers |
| `before_send`, `before_breadcrumb` | | Change an event or a breadcrumb, or drop it by returning `nil` |
| `error_budget` | 10 per issue, then 1 a minute; 600 a minute in all | Bounds the events sent; `enabled: false` sends every one |
| `max_breadcrumbs` | 100 | Breadcrumbs kept per scope |
| `max_value_length` | 1024 | Bytes of UTF-8 per string sent, cut on a character boundary and ending in `...` (masked before the cut) |
| `max_stack_frames` | 100 | Frames sent per exception, the newest kept |
| `send_default_pii` | off | Send the user's IP address and request headers that may identify them |
| `redact` | on | Mask secrets and personal data on the device |
| `sensitive_keys` | the server's (`password`, `token`, `cookie`, …) | Key fragments whose values are filtered whole; replaces the defaults |
| `context_lines` | 5 | Source lines around each of your frames; 0 turns it off |
| `project_root` | Bundler's root (Rails's root in Rails) | Files are named relative to it |
| `in_app_include`, `in_app_exclude` | | Module prefixes that are, or are not, your code |
| `auto_session_tracking` | on | A session per request, for release health (needs a release) |
| `capture_uncaught` | on | Report the exception that ends the process |
| `breadcrumbs_logger` | on | `Logger` records from `INFO` up as breadcrumbs |
| `trace_net_http` | on | `Net::HTTP` requests as client spans and breadcrumbs |
| `max_queue` | 100 | Events, traces and requests waiting to be sent, and as many waiting for a retry; past it, new data is dropped |
| `timeout` | 5 s | Of a request to Fixwire; it never follows a redirect, so the key goes to the DSN's host only |
| `shutdown_timeout` | 2 s | How long the exit waits to send what is left |
| `debug` | `FIXWIRE_DEBUG` | Logs what the SDK does and drops to stderr |

### Trace propagation targets

Trace headers go only to `trace_propagation_targets`, compared with the
URL without its user info, query and fragment:

- a string with `://` matches the URLs that start with it
  (`"https://api.example.com/v2"`);
- any other string is a host, with a port if it has one, and matches that
  host and its subdomains: `"example.com"` matches `api.example.com`, not
  `badexample.com` or `example.com.evil.net`;
- a `Regexp` is searched in the URL;
- a string starting with `/` matches only relative URLs, which Ruby's HTTP
  clients don't send.

### Before send

`before_send` sees every error and message after the scope is applied,
and may change it or drop it:

```ruby
Fixwire.init(
  before_send: lambda do |event|
    next nil if event.transaction == "GET /up" # never report the health check

    event.tags["region"] = "eu"
    event
  end,
  before_breadcrumb: ->(crumb) { crumb.category == "sql" ? nil : crumb }
)
```

An exception in `before_send` or `before_breadcrumb` is caught and logged
with `debug`; the event or breadcrumb goes on as it was.

### Sampling

`sample_rate` keeps a share of errors and messages. `traces_sample_rate`
decides each new trace from its trace id, the same way in every Fixwire
SDK, so the services of one trace agree. A trace continued from a caller
follows the caller's decision.

### Error budget

Each issue may send 10 events at once, then 1 a minute, within 600 a
minute across issues. Occurrences held back are counted and ride on the
issue's next event, so issue counts stay right. Change the numbers with
`error_budget: { per_issue_burst: 10, per_issue_per_minute: 1, per_minute: 600 }`,
or send every event with `error_budget: { enabled: false }`.

### Redaction

Secrets (keys, tokens, private keys, passwords in URLs) and personal data
(emails, card numbers, IBANs, phone numbers) are masked on the device,
with the same rules as the Fixwire server: in messages, attributes, span
names and status messages, breadcrumbs, feedback, URLs and their queries,
and the keys of maps. Redaction runs before a string is cut, over the part
kept and the next 16 kB, so a secret the cut goes through is still masked;
a value redaction fails on is sent as `[Filtered]`. The values of
sensitive keys (`sensitive_keys`) are filtered whole. Your app's own
configuration (release, environment, service and server names, a
monitor's slug and config) is cut to `max_value_length` but never masked:
`api@1.2.3.example` stays a release.

### Limits

Values (contexts, extras, attributes, breadcrumb data) are walked at most
10 levels deep and 100 items wide (10,000 objects each); a value that
holds itself is cut where it comes round again. An error or a message over
1 MB leaves out its breadcrumbs, then its contexts. A span keeps 128
attributes, a segment 1,000 child spans. Source lines come from files of
up to 10 MB, through a cache of at most 64 files and 32 MB. A request is
sent at most 4 times. A caller's `traceparent` is used only when it is
well formed, and its `tracestate` (512 bytes) and `baggage` (8 KB) are
passed on only within W3C's limits.

## 🧪 Examples

Real apps, run by their tests against a fake ingest, so they keep
working:

- [shop-api](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire/examples/shop-api):
  a Sinatra API with the Rack middleware, the signed-in user, a handled
  error with its cause, a traced call to another service and `Logger`
  breadcrumbs.
- [nightly-report](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire/examples/nightly-report):
  a cron job with check-ins to a monitor, one scope per account and a
  trace for the run.
- [Rails example](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire-rails/example):
  a Rails API with an Active Job job and a rake task, run with Puma and
  `rake`.

## 📚 Documentation

The full guide lives in this README and the examples.

- [Configuration](https://github.com/fixwire/fixwire-ruby#%EF%B8%8F-configuration)
- [Examples](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire/examples)
- [Changelog](https://github.com/fixwire/fixwire-ruby/blob/main/CHANGELOG.md)
- [Security policy](https://github.com/fixwire/fixwire-ruby/blob/main/SECURITY.md)
- [Contributing guide](https://github.com/fixwire/fixwire-ruby/blob/main/CONTRIBUTING.md)

## 🚧 Coming from another error tracker?

The API follows the shape most error-tracking SDKs share: `init`,
`capture_exception`, `capture_message`, `set_user`, `set_tag`,
`add_breadcrumb`, spans and scopes. Moving over is mostly a change of gem
and DSN. As Ruby has it, options are keywords (or a block), the current
scope lives per thread and fiber, and `Fixwire.trace` and
`Fixwire.with_scope` take a block.

## 🙌 Want to contribute?

We'd love your help, from a typo fix to a new integration. Read the
[contributing guide](https://github.com/fixwire/fixwire-ruby/blob/main/CONTRIBUTING.md),
then pick one of the
[open issues](https://github.com/fixwire/fixwire-ruby/issues) or a
[good first issue](https://github.com/fixwire/fixwire-ruby/issues?q=is%3Aopen+label%3A%22good+first+issue%22).

Each gem builds and tests on its own, its examples too:

```sh
cd fixwire && bundle install && bundle exec rake test && bundle exec rubocop
(cd examples && bundle install && bundle exec ruby test/examples_test.rb)
cd ../fixwire-rails && bundle install && bundle exec rake test && bundle exec rubocop
(cd example && bundle install && bundle exec ruby test/example_test.rb)
```

`RAILS_VERSION` and `SIDEKIQ_VERSION` pick the versions the tests run
against.

## 🛟 Need help?

- Questions: ask on [Discord](https://fixwire.io/discord) or
  [Slack](https://fixwire.io/slack).
- Bugs: open a [GitHub issue](https://github.com/fixwire/fixwire-ruby/issues).

Found a security issue? Please don't open an issue; follow the
[security policy](https://github.com/fixwire/fixwire-ruby/blob/main/SECURITY.md).

## 🔗 Resources

- [Website](https://fixwire.io)
- [Pricing](https://fixwire.io/pricing)
- [Discord](https://fixwire.io/discord)
- [Slack](https://fixwire.io/slack)
- [X](https://fixwire.io/x)
- [Changelog](https://github.com/fixwire/fixwire-ruby/blob/main/CHANGELOG.md)
- [Examples](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire/examples)
- [Security policy](https://github.com/fixwire/fixwire-ruby/blob/main/SECURITY.md)

## 📃 License

The SDK is open source under the MIT license; see
[LICENSE](https://github.com/fixwire/fixwire-ruby/blob/main/LICENSE).

## 😘 Contributors

Thanks to everyone who helps make Fixwire better!

<a href="https://github.com/fixwire/fixwire-ruby/graphs/contributors"><img src="https://contrib.rocks/image?repo=fixwire/fixwire-ruby" alt="Contributors" /></a>
