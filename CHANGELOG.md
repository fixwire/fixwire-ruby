# Changelog

All notable changes to the Fixwire Ruby SDK are listed here. Versions follow [Semantic
Versioning](https://semver.org); before 1.0, a minor version may change the
API.

## [0.1.0] - 2026-10-06

First release.

- `fixwire` (Ruby 3.2+, no dependencies): errors with their causes, the exception that ends the process, scopes per thread and fiber, spans, request sessions, cron monitors and feedback; a background sender that forked workers restart.
- Rack middleware, `Net::HTTP` tracing, `Logger` breadcrumbs, Rake task errors and Sidekiq jobs that continue the trace that pushed them.
- `fixwire-rails` (Rails 7.1+): what Rails reports, route-named requests, the signed-in user, Active Record queries and Active Job jobs continuing the trace that enqueued them.
- On-device redaction with the server's rules; an error budget for crash loops.
- Examples run against a fake ingest in CI: a Sinatra API, a cron job and a Rails app.
