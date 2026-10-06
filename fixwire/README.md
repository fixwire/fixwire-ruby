<div align="center">

_Bugs reach production. Fixwire finds them first: errors, traces, logs and
AI agent runs in one place, an AI debugger on every plan, and your data
kept in Europe._

[![Discord](https://img.shields.io/badge/Discord-join%20us-5865F2?logo=discord&logoColor=white)](https://fixwire.io/discord)
[![Slack](https://img.shields.io/badge/Slack-community-4A154B?logo=slack&logoColor=white)](https://fixwire.io/slack)
[![X](https://img.shields.io/badge/X-follow%20us-000000?logo=x&logoColor=white)](https://fixwire.io/x)
[![Release](https://img.shields.io/github/v/release/fixwire/fixwire-ruby?label=release)](https://github.com/fixwire/fixwire-ruby/releases)
[![Ruby](https://img.shields.io/badge/ruby-3.2%20%7C%203.3%20%7C%203.4%20%7C%204.0-blue?logo=ruby&logoColor=white)](https://github.com/fixwire/fixwire-ruby/blob/main/.github/workflows/ci.yml)
[![CI](https://github.com/fixwire/fixwire-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/fixwire/fixwire-ruby/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/fixwire/fixwire-ruby/blob/main/LICENSE)

<br/>

</div>

# Fixwire SDK for Ruby

Welcome to the official Ruby SDK for **[Fixwire](https://fixwire.io)**. It
captures errors with their causes, crashes, traces, release health, cron
monitors and user feedback from any Ruby program, with no runtime
dependencies. Rails apps install
[`fixwire-rails`](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire-rails),
which builds on this gem and sets everything up.

This is the short version: the
[repository README](https://github.com/fixwire/fixwire-ruby#readme) is
the full guide.

## 📦 Getting started

### Prerequisites

- A Fixwire account and project: sign up at
  [fixwire.io](https://fixwire.io).
- Ruby 3.2 or newer (tested on 3.2, 3.3, 3.4 and 4.0, on Linux, macOS and
  Windows).

### Installation

```sh
bundle add fixwire
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
tests and on your laptop. `init` never raises: an option that doesn't
exist is reported on stderr and ignored, and a broken DSN is reported on
stderr and leaves the SDK off.

Once started, the SDK reports the exception that ends the process (not
`exit` or Ctrl-C) as a crash, turns `Logger` records into breadcrumbs and
traces `Net::HTTP` requests. Sending happens on a background thread, so
capturing never waits; at exit, the SDK sends what is left.

### Quick usage example

```ruby
Fixwire.capture_message("Hello Fixwire!") # a message event, with the scope's user, tags and breadcrumbs

begin
  payments.charge(order)
rescue PaymentError => e
  Fixwire.capture_exception(e) # an issue: the exception, its causes and their stacks
end
```

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
- **No dependencies.** Ruby's standard library only.

## 🧩 Integrations

| Integration | What it does | How to use |
| --- | --- | --- |
| Rack (Sinatra, Hanami, Roda) | A scope, a release-health session and (with tracing on) a server span per request, named after its route; exceptions that escape the app, or that the framework turned into a 500, are crashes | `use Fixwire::Rack::Middleware` |
| Sidekiq | A job continues the trace that pushed it, in a scope of its own; a job that raises is a crash, with the job | `require "fixwire/sidekiq"` after `Fixwire.init` |
| `Net::HTTP` | Requests as client spans and breadcrumbs; trace headers to your `trace_propagation_targets` only | On by default (`trace_net_http`) |
| `Logger` | Records from `INFO` up become breadcrumbs | On by default (`breadcrumbs_logger`) |
| Rake | The exception that ends a task is a crash, named after the task | On when Rake is loaded |
| Rails and Active Job | See [`fixwire-rails`](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire-rails) | `bundle add fixwire-rails` |

Scopes, tracing, cron monitors and feedback are in the
[repository README](https://github.com/fixwire/fixwire-ruby#-integrations).

## ⚙️ Configuration

Every option, with its default, is in the
[configuration table](https://github.com/fixwire/fixwire-ruby#%EF%B8%8F-configuration),
along with how trace propagation targets match, `before_send`, sampling,
the error budget, redaction and limits.

## 🧪 Examples

- [shop-api](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire/examples/shop-api):
  a Sinatra API with the Rack middleware, the signed-in user and a traced
  call to another service.
- [nightly-report](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire/examples/nightly-report):
  a cron job with check-ins to a monitor and a trace for the run.

## 📚 Documentation

The full guide lives in the
[repository README](https://github.com/fixwire/fixwire-ruby#readme) and
the examples.

- [Configuration](https://github.com/fixwire/fixwire-ruby#%EF%B8%8F-configuration)
- [Examples](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire/examples)
- [Changelog](https://github.com/fixwire/fixwire-ruby/blob/main/CHANGELOG.md)
- [Security policy](https://github.com/fixwire/fixwire-ruby/blob/main/SECURITY.md)
- [Contributing guide](https://github.com/fixwire/fixwire-ruby/blob/main/CONTRIBUTING.md)

## 🚧 Coming from another error tracker?

The API follows the shape most error-tracking SDKs share: `init`,
`capture_exception`, `capture_message`, `set_user`, `set_tag`,
`add_breadcrumb`, spans and scopes. Moving over is mostly a change of gem
and DSN.

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
- [Examples](https://github.com/fixwire/fixwire-ruby/tree/main/fixwire/examples)
- [Security policy](https://github.com/fixwire/fixwire-ruby/blob/main/SECURITY.md)

## 📃 License

The SDK is open source under the MIT license; see
[LICENSE](https://github.com/fixwire/fixwire-ruby/blob/main/LICENSE).

## 😘 Contributors

Thanks to everyone who helps make Fixwire better!

<a href="https://github.com/fixwire/fixwire-ruby/graphs/contributors"><img src="https://contrib.rocks/image?repo=fixwire/fixwire-ruby" alt="Contributors" /></a>
