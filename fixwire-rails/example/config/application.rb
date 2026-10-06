# frozen_string_literal: true

require_relative "boot"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module Shop
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.api_only = true
    config.eager_load = Rails.env.production?
    config.logger = ActiveSupport::Logger.new($stdout)
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "example-only")
    config.hosts.clear
    config.active_job.queue_adapter = :async
  end
end
