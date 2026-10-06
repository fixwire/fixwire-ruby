<div align="center">

_Bugs reach production. Fixwire finds them first: errors, traces, logs and
AI agent runs in one place, an AI debugger on every plan, and your data
kept in Europe._

[![Discord](https://img.shields.io/badge/Discord-join%20us-5865F2?logo=discord&logoColor=white)](https://fixwire.io/discord)
[![Slack](https://img.shields.io/badge/Slack-community-4A154B?logo=slack&logoColor=white)](https://fixwire.io/slack)
[![X](https://img.shields.io/badge/X-follow%20us-000000?logo=x&logoColor=white)](https://fixwire.io/x)
[![Release](https://img.shields.io/github/v/release/fixwire/fixwire-ruby?label=release)](https://github.com/fixwire/fixwire-ruby/releases)
[![Rails](https://img.shields.io/badge/rails-7.1%20%7C%207.2%20%7C%208.0%20%7C%208.1-blue?logo=rubyonrails&logoColor=white)](https://github.com/fixwire/fixwire-ruby/blob/main/.github/workflows/ci.yml)
[![CI](https://github.com/fixwire/fixwire-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/fixwire/fixwire-ruby/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/fixwire/fixwire-ruby/blob/main/LICENSE)

<br/>

</div>

# Fixwire SDK for Rails

Welcome to the official Rails SDK for **[Fixwire](https://fixwire.io)**.
It captures the exceptions Rails reports, each request as a trace named
after its route, the signed-in user, Active Record queries, Active Job
jobs, rake tasks, cron monitors and release health. It builds on the
[Ruby SDK](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire)
(the `fixwire` gem), which comes with it.

This is the short version: the
[repository README](https://github.com/fixwire/fixwire-ruby#readme) is
the full guide.

## 📦 Getting started

### Prerequisites

- A Fixwire account and project: sign up at
  [fixwire.io](https://fixwire.io).
- Rails 7.1 or newer (tested on 7.1, 7.2, 8.0 and 8.1) on Ruby 3.2 or
  newer.

### Installation

```sh
bundle add fixwire-rails
```

### Basic configuration

Set the DSN in the app's environment:

```sh
FIXWIRE_DSN=https://fw_pk_live_…@ingest.eu.fixwire.io
FIXWIRE_RELEASE=shop@1.4.0
```

That's all: with `FIXWIRE_DSN` in the environment, Fixwire starts with the
app, using Rails's environment and root. The DSN is your project's
publishable key and the ingest host: `https://<publishable key>@<host>`.
Without a DSN (development, your test suite) it does nothing. To set more,
start it yourself:

```ruby
# config/initializers/fixwire.rb
Fixwire.init(
  release: ENV["FIXWIRE_RELEASE"],
  # send_default_pii: true, # also send users' IP addresses, emails and identifying headers
  # redact: false,          # stop masking secrets and personal data on the device
  traces_sample_rate: 0.2,  # keep a fifth of new traces
  trace_propagation_targets: [ENV["INVENTORY_URL"]]
)
```

`init` never raises: an option that doesn't exist is reported on stderr
and ignored, and a broken DSN is reported on stderr and leaves the SDK
off, so the app always boots.

### Quick usage example

```ruby
Fixwire.capture_message("Hello Fixwire!") # a message event, with the request, user and breadcrumbs

begin
  payments.charge(order)
rescue PaymentError => e
  Rails.error.report(e, handled: true) # an issue: the exception, its causes and their stacks
end
```

`Fixwire.capture_exception(e)` works too; each exception is sent once.

## ✨ Why Fixwire

- **Secrets stay on the device.** Secrets and personal data are masked
  before anything is sent, with the same rules as the Fixwire server.
- **A crash loop costs a few events and a count, not your quota.**
- **It never gets in your app's way.** `init` never raises, capturing
  never waits, and memory and time stay bounded.
- **OpenTelemetry-native.** It speaks the Fixwire protocol
  (OpenTelemetry's OTLP/HTTP plus a few small JSON endpoints).
- **Trace headers only where you allow**, and **your data stays in
  Europe**.

## 🧩 Integrations

| Integration | What it does | How to use |
| --- | --- | --- |
| `Rails.error` | Exceptions Rails reports, with the request, the route, the user and the breadcrumbs (log lines, SQL queries without their values, HTTP calls); client errors (404s, bad parameters) aren't sent | Automatic |
| Requests | A scope, a release-health session and (with tracing on) a server span per request, named after its route, with its queries and HTTP calls under it | Automatic |
| Signed-in user | `Current.user` (Rails's authentication generator) or Warden (Devise): the id, plus the email with `send_default_pii` | Automatic; `Fixwire::Rails.user = ->(env) { … }` sets your own |
| Active Job | A job continues the trace that enqueued it, in a scope of its own (the queue as a tag, the job as context); a job that raises is a crash | Automatic |
| Rake | The exception that ends a task is a crash, named after the task | Automatic |
| Sidekiq | Jobs that don't go through Active Job | `require "fixwire/sidekiq"` in the initializer |

Cron monitors for rake tasks:

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

## ⚙️ Configuration

Every option, with its default, is in the
[configuration table](https://github.com/fixwire/fixwire-ruby#%EF%B8%8F-configuration),
along with how trace propagation targets match, `before_send`, sampling,
the error budget, redaction and limits.

## 🧪 Examples

- [Rails example](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire-rails/example):
  a Rails API with an Active Job job and a rake task, run by its test with
  Puma and `rake` against a fake ingest.

## 📚 Documentation

The full guide lives in the
[repository README](https://github.com/fixwire/fixwire-ruby#readme) and
the examples.

- [Configuration](https://github.com/fixwire/fixwire-ruby#%EF%B8%8F-configuration)
- [Examples](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire-rails/example)
- [Changelog](https://github.com/fixwire/fixwire-ruby/blob/main/CHANGELOG.md)
- [Security policy](https://github.com/fixwire/fixwire-ruby/blob/main/SECURITY.md)
- [Contributing guide](https://github.com/fixwire/fixwire-ruby/blob/main/CONTRIBUTING.md)

## 🚧 Coming from another error tracker?

The API follows the shape most error-tracking SDKs share: `init`,
`capture_exception`, `capture_message`, `set_user`, `set_tag`,
`add_breadcrumb`, spans and scopes, and it reads what Rails reports
through `Rails.error`. Moving over is mostly a change of gem and DSN.

## 🙌 Want to contribute?

We'd love your help, from a typo fix to a new integration. Read the
[contributing guide](https://github.com/fixwire/fixwire-ruby/blob/main/CONTRIBUTING.md),
then pick one of the
[open issues](https://github.com/fixwire/fixwire-ruby/issues) or a
[good first issue](https://github.com/fixwire/fixwire-ruby/issues?q=is%3Aopen+label%3A%22good+first+issue%22).

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
- [Examples](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire-rails/example)
- [Security policy](https://github.com/fixwire/fixwire-ruby/blob/main/SECURITY.md)

## 📃 License

The SDK is open source under the MIT license; see
[LICENSE](https://github.com/fixwire/fixwire-ruby/blob/main/LICENSE).

## 😘 Contributors

Thanks to everyone who helps make Fixwire better!

<a href="https://github.com/fixwire/fixwire-ruby/graphs/contributors"><img src="https://contrib.rocks/image?repo=fixwire/fixwire-ruby" alt="Contributors" /></a>
