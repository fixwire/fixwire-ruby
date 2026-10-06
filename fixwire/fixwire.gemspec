# frozen_string_literal: true

require_relative "lib/fixwire/version"

Gem::Specification.new do |spec|
  spec.name = "fixwire"
  spec.version = Fixwire::VERSION
  spec.summary = "Fixwire SDK for Ruby: errors, traces, release health, cron monitors and feedback"
  spec.description = "Reports errors with their causes, traces, request sessions, check-ins and feedback to Fixwire " \
                     "over OpenTelemetry's OTLP/HTTP. Rack middleware, Net::HTTP tracing and Logger breadcrumbs; " \
                     "secrets and personal data are masked on the device. No runtime dependencies."
  spec.authors = ["Fixwire"]
  spec.homepage = "https://fixwire.io"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.metadata = {
    "homepage_uri" => "https://fixwire.io",
    "source_code_uri" => "https://github.com/fixwire/fixwire/tree/main/sdks/ruby/fixwire",
    "rubygems_mfa_required" => "true"
  }
end
