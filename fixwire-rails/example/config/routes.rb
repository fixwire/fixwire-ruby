# frozen_string_literal: true

Rails.application.routes.draw do
  get "/orders/:id", to: "orders#show"
  post "/orders", to: "orders#create"
  get "/admin/report", to: "orders#report"
end
