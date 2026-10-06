# frozen_string_literal: true

require "rails/railtie"

module Fixwire
  module Rails
    class Railtie < ::Rails::Railtie
      # Before the app's initializers: Fixwire.init there gets Rails's environment and root.
      initializer "fixwire.defaults", before: :load_config_initializers do |app|
        Fixwire::Options.framework_defaults[:environment] = -> { ::Rails.env.to_s }
        Fixwire::Options.framework_defaults[:project_root] = -> { app.root.to_s }
      end

      initializer "fixwire.middleware" do |app|
        app.config.middleware.insert(0, Fixwire::Rails::Middleware)
      end

      initializer "fixwire.active_job" do
        ActiveSupport.on_load(:active_job) { prepend Fixwire::Rails::ActiveJob }
      end

      # Without Fixwire.init in an initializer, the environment's FIXWIRE_DSN is enough.
      config.after_initialize do
        Fixwire.init unless Fixwire.initialized? || ENV.fetch("FIXWIRE_DSN", "").strip.empty?
        ::Rails.error.subscribe(Fixwire::Rails::ErrorSubscriber.new) if ::Rails.respond_to?(:error)
        Fixwire::Rails::Queries.subscribe if defined?(::ActiveRecord)
        Fixwire::Rails::Routes.subscribe
      end
    end
  end
end
