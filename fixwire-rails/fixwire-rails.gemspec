# frozen_string_literal: true

require_relative "../fixwire/lib/fixwire/version"

Gem::Specification.new do |spec|
  spec.name = "fixwire-rails"
  spec.version = Fixwire::VERSION
  spec.summary = "Fixwire for Rails: errors, traces, Active Job, Active Record and release health"
  spec.description = "Sets Fixwire up in a Rails app: the exceptions Rails reports, each request as a trace named " \
                     "after its route, Active Record queries, Active Job jobs continuing the trace that enqueued them."
  spec.authors = ["Fixwire"]
  spec.homepage = "https://fixwire.io"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.add_dependency "fixwire", Fixwire::VERSION
  spec.add_dependency "railties", ">= 7.1"
  spec.metadata = {
    "homepage_uri" => "https://fixwire.io",
    "source_code_uri" => "https://github.com/fixwire/fixwire-ruby/tree/main/fixwire-rails",
    "changelog_uri" => "https://github.com/fixwire/fixwire-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/fixwire/fixwire-ruby/issues",
    "rubygems_mfa_required" => "true"
  }
end
