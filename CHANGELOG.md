# Changelog

All notable changes to the Fixwire Ruby SDK are listed here. Versions follow [Semantic
Versioning](https://semver.org); before 1.0, a minor version may change the
API.

## [Unreleased]

- A forked child (Puma's and Unicorn's workers) starts its sender at once, so it sends its request sessions even when it captures nothing, and leaves the parent's sessions to the parent.
- The error budget fingerprints a message in linear time from its first 1024 characters: a hostile message no longer stalls `capture_message` for seconds, and broken UTF-8 messages are sent instead of dropped.
- An error or message over 1 MB is sent without its breadcrumbs, else dropped alone; log and span requests stay under 5 MB and session requests under 5000 aggregates, so one oversized record no longer sinks its batch.
- A failed span's status message goes through redaction.
- Without `send_default_pii`, the `Forwarded`, `CF-Connecting-IP`, `True-Client-IP` and `X-Client-IP` request headers (the user's IP address) are left out too.
- Values that hold themselves (a tree whose nodes know their parent) are cut at the cycle (`"[Circular ~]"`) instead of being expanded until the depth limit.
- On-device redaction numbers thousands of keys that mask alike (such as request headers) in linear time.
- A caller's `tracestate` over 512 bytes and `baggage` over 8 KB are not passed on to other services or jobs.
- The answer's body is never read; rate-limit pauses last at most a day and only name known kinds of data.
- `Logger` breadcrumbs: logging inside `before_breadcrumb` no longer recurses.
- The Rack middleware lets a request it can't read (text in clashing encodings) go on untracked; Sidekiq and Active Job jobs whose payload holds something other than a trace under `fixwire` run as usual.
- Strings in other encodings are converted to UTF-8, not reinterpreted.

## [0.1.0] - 2026-10-06

First release.

- `fixwire` (Ruby 3.2+, no dependencies): errors with their causes, the exception that ends the process, scopes per thread and fiber, spans, request sessions, cron monitors and feedback; a background sender that forked workers restart.
- Rack middleware, `Net::HTTP` tracing, `Logger` breadcrumbs, Rake task errors and Sidekiq jobs that continue the trace that pushed them.
- `fixwire-rails` (Rails 7.1+): what Rails reports, route-named requests, the signed-in user, Active Record queries and Active Job jobs continuing the trace that enqueued them.
- On-device redaction with the server's rules; an error budget for crash loops.
- Examples run against a fake ingest in CI: a Sinatra API, a cron job and a Rails app.
