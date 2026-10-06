# Changelog

All notable changes to the Fixwire Ruby SDK are listed here. Versions follow [Semantic
Versioning](https://semver.org); before 1.0, a minor version may change the
API.

## [Unreleased]

- `Fixwire.init` never raises. An unknown option (a keyword, or set in the block) is reported on stderr and ignored, and the rest of the options still apply (it used to raise `ArgumentError`). A broken DSN is reported on stderr even without `debug`, and the SDK stays off. Any other failure in `init`, such as the block raising, is reported the same way: the SDK stays off and `init` returns `nil`.
- A forked child (Puma's and Unicorn's workers) starts its sender at once, so it sends its request sessions even when it captures nothing, and leaves the parent's sessions to the parent.
- The error budget fingerprints a message in linear time from its first 1024 characters: a hostile message no longer stalls `capture_message` for seconds, and broken UTF-8 messages are sent instead of dropped.
- An error or message over 1 MB is sent without its breadcrumbs, then without its contexts, else dropped alone; log and span requests stay under 5 MB (a span that can't fit is dropped alone) and session requests under 5000 aggregates, so one oversized record no longer sinks its batch.
- A failed span's status message goes through redaction.
- Without `send_default_pii`, the `Forwarded`, `CF-Connecting-IP`, `True-Client-IP` and `X-Client-IP` request headers (the user's IP address) are left out too.
- Values that hold themselves (a tree whose nodes know their parent) are cut at the cycle (`"[Circular ~]"`) instead of being expanded until the depth limit.
- On-device redaction numbers thousands of keys that mask alike (such as request headers) in linear time.
- A caller's `tracestate` over 512 bytes and `baggage` over 8 KB, or either holding a control character other than tab, are not passed on to other services or jobs; a `traceparent` is continued only with version `00`, exactly four parts and lower-case hex (an upper-case one is ignored, not lowercased).
- The answer's body is never read; rate-limit pauses last at most a day and only name known kinds of data.
- `max_value_length` (default 1024): every string sent is at most that many bytes of UTF-8, cut on a character boundary and ending in `...`; redaction runs first, over the part kept and the next 16 kB, so a key or token the cut goes through is still masked.
- Values are walked at most 10 levels deep, 100 items wide and 10,000 objects per value: `"[Object]"` / `"[Array]"` past that, `"[Unreadable]"` for an object whose `to_s` raises (was `"[too deep]"` and the class name).
- `max_stack_frames` (default 100): the newest frames of each exception are kept.
- Source lines come from files of up to 10 MB (was 1 MB), through a cache of at most 64 files and 32 MB.
- A span keeps at most 128 attributes; at most 5000 users are counted apart per sessions send, the rest without their user.
- Retries: a request is sent at most 4 times in all. It is sent again after no answer or a 5xx, after 1, 2 and 4 s (was twice, after 0.5 and 2 s), and after a 429's pause (a 429 used to be dropped), without holding up other sending; a 5xx with `Retry-After` pauses all data for that long; a request whose next try is over 5 minutes away is dropped; at most `max_queue` requests wait for a retry.
- `Retry-After` is read as seconds or an HTTP date; broken `Fixwire-Rate-Limits` seconds are ignored instead of read leniently.
- `max_queue` defaults to 100 (was 1000), and a segment's spans count as one entry.
- `trace_propagation_targets`: a string without `://` is a host matching itself and its subdomains (`example.com` no longer matches `badexample.com` or `example.com.evil.net`), compared without user info, query and fragment; a string with `://` is a URL prefix; a `Regexp` is searched in the URL.
- Redaction: secrets given to compound names (`access_token`, `client_secret`, `csrfToken`, `PHPSESSID`, `X-Amz-Signature`) and an OAuth `code` in a query or fragment are masked, as on the server; text a detector fails on is sent as `[Filtered]`; span names, operations and feedback's source and ids go through redaction too.
- Entry points and app objects never raise into the app: a breadcrumb with unknown fields, a `before_breadcrumb` returning something else, a message, tag, span name or route whose `to_s` raises; `before_breadcrumb` failures are logged; `Logger` records written from `before_send` or `before_breadcrumb` are not kept as breadcrumbs.
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
