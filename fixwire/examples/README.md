# Examples

Real apps, each with its own README. `test/examples_test.rb` runs them as
they run for real (Puma, the CLI) against a fake ingest and checks what
Fixwire receives, so they keep working:

```sh
bundle install && bundle exec ruby test/examples_test.rb
```

| Example | Shows |
|---|---|
| [shop-api](shop-api) | A Sinatra API: `Fixwire::Rack::Middleware` (a scope, a session and a server span per request named after its route, exceptions Sinatra turned into a 500 reported as crashes), the signed-in user, a handled error with context and its cause, 404s not reported, a database span, a `Net::HTTP` call to another service with trace headers sent only to it, `Logger` records as breadcrumbs, sending what is left when Puma stops |
| [nightly-report](nightly-report) | A cron job: check-ins to a monitor (created from the first one), one scope per account, carrying on after a failure, a summary warning, a trace for the run, an exit code |

They install the SDK from this repository (`path: ".."` in the `Gemfile`);
an app of yours adds `gem "fixwire"`. Rails apps: see
[fixwire-rails](../../fixwire-rails).
