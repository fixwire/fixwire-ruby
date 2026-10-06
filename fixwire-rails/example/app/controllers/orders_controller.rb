# frozen_string_literal: true

User = Struct.new(:id)

class OrdersController < ActionController::API
  # The signed-in user (here: a header; a token, in a real app).
  before_action { Current.user = User.new(request.headers["X-User-Id"]) if request.headers["X-User-Id"] }

  def show
    # A query: a breadcrumb, and a span under the request's.
    order = ActiveRecord::Base.connection.select_one("select #{params[:id].to_i} as id, 'paid' as status")
    render json: order
  end

  def create
    order = params.require(:order).permit(:sku, :card) # a 400 is not reported
    Rails.logger.info("order received")
    ReserveStockJob.perform_later(order[:sku])
    id = "ord_#{SecureRandom.hex(4)}"
    if order[:card] == "4000000000000002" # the test card that is always declined
      # Handled: the customer gets an answer, Fixwire gets the error with the order.
      Fixwire.with_scope do |scope|
        scope.set_context("order", { id: id, sku: order[:sku] })
        Rails.error.report(RuntimeError.new("charging order #{id}: card_declined"), handled: true)
      end
      return render json: { error: "payment declined" }, status: :payment_required
    end
    render json: { id: id }, status: :created
  end

  def report
    cents = [] # today's orders: none yet
    # A bug: with no orders this divides by zero. Rails answers 500 and reports it; so does Fixwire.
    render json: { average_cents: cents.sum / cents.size }
  end
end
