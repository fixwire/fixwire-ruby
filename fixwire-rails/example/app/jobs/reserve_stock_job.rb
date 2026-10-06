# frozen_string_literal: true

require "net/http"

# Holds one item at the inventory service. Enqueued by an order, it continues the order's trace.
class ReserveStockJob < ActiveJob::Base
  def perform(sku)
    uri = URI("#{ENV.fetch("INVENTORY_URL", "http://localhost:8081")}/reservations?sku=#{sku}")
    response = Net::HTTP.post(uri, "", "Content-Type" => "application/json")
    raise "reserving #{sku}: inventory answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    Rails.logger.info("stock reserved")
  end
end
