# frozen_string_literal: true

# A small JSON API on Sinatra reporting to Fixwire: each request gets its own scope and a trace
# named after its route, an exception the app didn't rescue is a crash, a failed payment is
# reported with the order as context, the call to the inventory service is traced, and log
# records become breadcrumbs.
#
#   FIXWIRE_DSN=https://<key>@<host> bundle exec rackup shop-api/config.ru -p 8080

require "logger"
require "fixwire"
require "sinatra/base"
require "json"
require "net/http"

INVENTORY_URL = ENV.fetch("INVENTORY_URL", "http://localhost:8081")

# The DSN comes from FIXWIRE_DSN; without it, Fixwire does nothing.
Fixwire.init(
  release: ENV.fetch("RELEASE", "shop-api@1.0.0"),
  traces_sample_rate: 1.0,
  # Trace headers go to our own inventory service, nowhere else.
  trace_propagation_targets: [INVENTORY_URL]
)

# What the payment provider answers with.
class PaymentDeclined < StandardError; end

class ShopApi < Sinatra::Base
  # Fixwire first: it sees each request, and the exceptions that escape the app.
  use Fixwire::Rack::Middleware

  set :show_exceptions, false
  set :raise_errors, false # Sinatra answers 500; the middleware reports what it rescued
  set :logger, Logger.new($stderr)

  # The catalog stands in for a database.
  PRODUCTS = {
    "sku_1" => { id: "sku_1", name: "Mug", price_cents: 1200 },
    "sku_2" => { id: "sku_2", name: "Poster", price_cents: 2500 }
  }.freeze

  before do
    content_type :json
    # The signed-in user (here: a header), on the request's scope.
    Fixwire.set_user(id: request.env["HTTP_X_USER_ID"]) if request.env["HTTP_X_USER_ID"]
  end

  get "/products/:id" do
    # A span for the lookup, under the request's.
    product = Fixwire.trace("SELECT products", op: "db.query", attributes: { "db.system.name" => "postgresql" }) do
      PRODUCTS[params[:id]]
    end
    halt 404, { error: "no such product" }.to_json unless product # a 404 is not an error worth reporting
    product.to_json
  end

  post "/orders" do
    order = JSON.parse(request.body.read) rescue {} # rubocop:disable Style/RescueModifier
    halt 400, { error: "bad order" }.to_json unless order["sku"].is_a?(String) && order["card"].is_a?(String)
    Fixwire.set_tag("sku", order["sku"])
    settings.logger.info("order received")

    begin
      reserve(order["sku"])
    rescue StandardError => e
      Fixwire.capture_exception(e)
      halt 409, { error: "out of stock" }.to_json
    end
    id = "ord_#{SecureRandom.hex(4)}"

    begin
      charge(order["card"])
    rescue PaymentDeclined
      # Handled: the customer gets an answer, Fixwire gets the error with the order.
      Fixwire.with_scope do |scope|
        scope.set_context("order", { id: id, sku: order["sku"] })
        begin
          raise "charging order #{id}"
        rescue RuntimeError => wrapped
          Fixwire.capture_exception(wrapped) # its cause is the PaymentDeclined
        end
      end
      halt 402, { error: "payment declined" }.to_json
    end
    status 201
    { id: id }.to_json
  end

  get "/admin/report" do
    cents = [] # today's orders: none yet
    # A bug: with no orders this divides by zero. Sinatra answers 500; Fixwire reports it.
    { average_cents: cents.sum / cents.size }.to_json
  end

  private

  # Asks the inventory service to hold one item: a traced call.
  def reserve(sku)
    uri = URI("#{INVENTORY_URL}/reservations?sku=#{sku}")
    response = Net::HTTP.post(uri, "", "Content-Type" => "application/json")
    raise "reserving #{sku}: inventory answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  end

  def charge(card)
    raise PaymentDeclined, "payment declined: card_declined" if card == "4000000000000002" # the test card that is always declined
  end
end
