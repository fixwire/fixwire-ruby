# frozen_string_literal: true

require "uri"

module Fixwire
  # Where to send and with which key: https://<key>@<host>[/<path>].
  class Dsn
    attr_reader :key, :base_url

    def self.parse(value)
      text = value.to_s.strip
      raise ArgumentError, "fixwire: empty DSN" if text.empty?

      uri = URI.parse(text)
      raise ArgumentError, "fixwire: a DSN is http(s)://<key>@<host>" unless %w[http https].include?(uri.scheme) && uri.host
      raise ArgumentError, "fixwire: the DSN has no key" if uri.user.to_s.empty?

      port = uri.port == uri.default_port ? "" : ":#{uri.port}"
      new(URI.decode_www_form_component(uri.user), "#{uri.scheme}://#{uri.host}#{port}#{uri.path.chomp("/")}")
    rescue URI::InvalidURIError
      raise ArgumentError, "fixwire: the DSN is not a URL"
    end

    def initialize(key, base_url)
      @key = key
      @base_url = base_url
    end

    def url(path)
      base_url + path
    end
  end
end
