# Fixwire for Ruby

[![CI](https://github.com/fixwire/fixwire-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/fixwire/fixwire-ruby/actions/workflows/ci.yml)

The Fixwire SDKs for Ruby: errors with their causes, traces, release health,
cron monitors and feedback. Secrets and personal data are masked on the
device, with the same rules as the Fixwire server.

| Gem | For |
|---|---|
| [`fixwire`](fixwire) | Ruby 3.2+, no dependencies: any Ruby program, Rack apps (Sinatra, Hanami, Roda), `Net::HTTP`, `Logger`, Rake and Sidekiq |
| [`fixwire-rails`](fixwire-rails) | Rails 7.1+: what Rails reports, route-named requests, the signed-in user, Active Record and Active Job |

```ruby
# Gemfile
gem "fixwire-rails" # or, outside Rails: gem "fixwire"
```

```sh
FIXWIRE_DSN=https://fw_pk_live_…@ingest.eu.fixwire.io
```

Each gem's README has the details. The examples, run against a fake ingest
in CI so they keep working: a Sinatra API and a cron job
([fixwire/examples](fixwire/examples)), and a Rails app
([fixwire-rails/example](fixwire-rails/example)).

## Development

```sh
cd fixwire && bundle install && bundle exec rake test && bundle exec rubocop
cd fixwire-rails && bundle install && bundle exec rake test && bundle exec rubocop
```

`RAILS_VERSION` and `SIDEKIQ_VERSION` pick the versions the tests run
against (CI covers Rails 7.1 to 8.1 and Sidekiq 7 and 8).

## License

[MIT](LICENSE)
