# Shop (Rails)

A small Rails API with Fixwire, installed the way an app would install it:
`fixwire-rails` in the `Gemfile`, the DSN in the environment and
`config/initializers/fixwire.rb`.

```sh
bundle install
FIXWIRE_DSN=https://<key>@<host> RAILS_ENV=production bundle exec puma config.ru -p 8080
```

It reserves stock at an inventory service in an Active Job job
(`INVENTORY_URL`, default `http://localhost:8081`). The API knows its users
from an `X-User-Id` header (a token, in a real app), and keeps the user in
`Current.user`. Then:

```sh
curl localhost:8080/orders/7                                          # 200, with a query span
curl -H 'Content-Type: application/json' -d '{}' localhost:8080/orders # 400: not reported
curl -H 'X-User-Id: user-2' -H 'Content-Type: application/json' \
  -d '{"order":{"sku":"sku_2","card":"4000000000000002"}}' localhost:8080/orders # 402
curl localhost:8080/admin/report                                      # a bug: 500
FIXWIRE_DSN=… RAILS_ENV=production bundle exec rake reports:send      # the nightly reports
```

What arrives in Fixwire:

- **The declined payment**, reported with `Rails.error.report(…, handled:
  true)` inside `Fixwire.with_scope` (so with the order as context), with
  the user `user-2` and the breadcrumbs (`order received`, the query).
- **The bug** in `GET /admin/report` (`ZeroDivisionError`), reported by
  Rails, as a crash.
- **A trace per request**, named after its route, with the SQL query, and
  the `ReserveStockJob` job under the order. The job continues the order's
  trace, and its call to the inventory service carries the trace on.
- **The nightly reports**: check-ins for the `nightly-report` monitor
  (`in_progress`, then `error`), and the task's failure as a crash named
  `rake reports:send`.
