# Shop API (Sinatra)

A small JSON API with Fixwire set up the way a production service would be.

```sh
bundle install    # in examples/
FIXWIRE_DSN=https://<key>@<host> bundle exec rackup shop-api/config.ru -p 8080
```

It reserves stock at an inventory service (`INVENTORY_URL`, default
`http://localhost:8081`; without one, orders fail at the reservation, and
that is reported too). Then:

```sh
curl localhost:8080/products/sku_1                      # 200, with a database span
curl localhost:8080/products/nope                       # 404: not reported
curl -H 'X-User-Id: user-1' -d '{"sku":"sku_1","card":"4242424242424242"}' localhost:8080/orders
curl -H 'X-User-Id: user-2' -d '{"sku":"sku_2","card":"4000000000000002"}' localhost:8080/orders
curl localhost:8080/admin/report                        # a bug: reported as a crash, answered 500
```

What arrives in Fixwire:

- **The declined payment** as an error of `POST /orders`: the chain
  (`charging order …` caused by `PaymentDeclined`), the user `user-2`, the
  `sku` tag, the order as context, and the breadcrumbs that led to it (the
  `order received` log line, the call to the inventory service). The card
  number stays in the app.
- **The bug** in `GET /admin/report` as a crash (`ZeroDivisionError`),
  with the stack where it happened.
- **A trace per request**, named after its route (`GET /products/:id`),
  with the database lookup and the call to the inventory service under it.
  The inventory service gets a `traceparent` header and continues the
  trace; other hosts get none (`trace_propagation_targets`).
- **Release health** for `shop-api@1.0.0`: each request is a session, ended
  well, with an error, or crashed. The counts go out every minute, and when
  Puma stops.

How it is wired, in `app.rb`:

```ruby
Fixwire.init(
  release: "shop-api@1.0.0",
  traces_sample_rate: 1.0,
  trace_propagation_targets: [INVENTORY_URL]
)

class ShopApi < Sinatra::Base
  use Fixwire::Rack::Middleware
  set :raise_errors, false # Sinatra answers 500; the middleware reports what it rescued
end
```

Handlers set things on their request's scope with `Fixwire.set_user`,
`Fixwire.set_tag` and the like.
