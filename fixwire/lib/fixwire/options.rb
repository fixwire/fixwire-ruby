# frozen_string_literal: true

require "socket"

module Fixwire
  # The SDK's options. Fixwire.init takes them as keywords (an unknown one is an error) or sets them
  # in a block.
  class Options
    DEFAULTS = {
      dsn: nil,                       # FIXWIRE_DSN when not set; nothing is sent without one
      release: nil,                   # FIXWIRE_RELEASE: the app's version, such as shop@1.4.0
      environment: nil,               # FIXWIRE_ENVIRONMENT, else RAILS_ENV / RACK_ENV, else production
      server_name: nil,               # the host name
      service_name: nil,              # OTEL_SERVICE_NAME, else "shop" of a shop@1.4.0 release
      sample_rate: 1.0,               # the share of errors and messages sent
      traces_sample_rate: 0.0,        # the share of new traces kept (continued ones follow the caller)
      trace_propagation_targets: [],  # where outgoing requests carry trace headers: URL prefixes, hosts, regexps
      before_send: nil,               # ->(event) { event or nil }: change an event, or drop it
      before_breadcrumb: nil,         # ->(breadcrumb) { breadcrumb or nil }
      max_breadcrumbs: 100,
      max_value_length: 1024,         # bytes of UTF-8 a string sent keeps (cut ones end in "...")
      max_stack_frames: 100,          # frames kept per exception, the newest
      send_default_pii: false,        # the user's IP address and identifying request headers
      redact: true,                   # mask secrets and personal data on the device, as the server does
      sensitive_keys: nil,            # key fragments whose values are filtered whole; nil for the server's
      error_budget: {},               # per_issue_burst (10), per_issue_per_minute (1), per_minute (600), enabled
      in_app_include: [],             # module prefixes that are your code
      in_app_exclude: [],             # module prefixes that are not
      project_root: nil,              # where your code is (files are named relative to it): Bundler's root
      context_lines: 5,               # source lines kept around each of your frames
      auto_session_tracking: true,    # a session per request, for release health (needs a release)
      capture_uncaught: true,         # report the exception that ends the process
      breadcrumbs_logger: true,       # ::Logger records from INFO become breadcrumbs
      trace_net_http: true,           # Net::HTTP requests are client spans and breadcrumbs
      max_queue: 100,                 # what waits to be sent (events, traces, requests), and as many retries
      shutdown_timeout: 2.0,          # how long the exit waits to send what is left
      timeout: 5.0,                   # of a request to Fixwire
      debug: false,                   # log what the SDK does, and what it drops, to stderr (FIXWIRE_DEBUG=1)
      transport: nil                  # sends to Fixwire; for tests
    }.freeze

    attr_accessor(*DEFAULTS.keys)

    # Defaults a framework integration sets before the app's own options (Rails: its environment
    # and root); values may be callables, read when the SDK starts.
    def self.framework_defaults = (@framework_defaults ||= {})

    def initialize(**options)
      DEFAULTS.each { |name, value| public_send(:"#{name}=", value.dup) }
      Options.framework_defaults.each { |name, value| public_send(:"#{name}=", value.respond_to?(:call) ? value.call : value) }
      options.each do |name, value|
        raise ArgumentError, "fixwire: no option #{name.inspect}" unless DEFAULTS.key?(name.to_sym)

        public_send(:"#{name}=", value)
      end
    end

    # Fills in what is not set, from the environment.
    def apply_defaults!
      self.dsn = env(dsn, "FIXWIRE_DSN")
      self.release = env(release, "FIXWIRE_RELEASE")
      self.environment = env(environment, "FIXWIRE_ENVIRONMENT") || env(nil, "RAILS_ENV") || env(nil, "RACK_ENV") || "production"
      self.server_name = blank?(server_name) ? Socket.gethostname : server_name
      self.service_name = env(service_name, "OTEL_SERVICE_NAME")
      self.service_name = release.split("@", 2).first if blank?(service_name) && release.to_s.index("@").to_i.positive?
      self.debug ||= %w[1 true yes on].include?(ENV.fetch("FIXWIRE_DEBUG", "").strip.downcase)
      self.sample_rate = 1.0 unless sample_rate.to_f.positive? && sample_rate.to_f <= 1
      self.traces_sample_rate = traces_sample_rate.to_f.clamp(0.0, 1.0)
      self.max_value_length = whole(max_value_length, 4, 1024) # room for "..."
      self.max_stack_frames = whole(max_stack_frames, 1, 100)
      self.max_queue = whole(max_queue, 1, 100)
      self.project_root = File.expand_path(project_root || default_root).chomp("/")
      self
    end

    def sessions?
      auto_session_tracking && !blank?(release)
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    private

    def env(value, name)
      return value unless blank?(value)

      found = ENV.fetch(name, nil)
      blank?(found) ? nil : found
    end

    # A whole number of at least min, else the default.
    def whole(value, min, default)
      value.is_a?(Integer) && value >= min ? value : default
    end

    def default_root
      defined?(::Bundler) && ::Bundler.respond_to?(:root) ? ::Bundler.root.to_s : Dir.pwd
    rescue StandardError
      Dir.pwd
    end
  end
end
