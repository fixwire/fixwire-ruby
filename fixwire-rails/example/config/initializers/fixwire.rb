# frozen_string_literal: true

# The DSN comes from FIXWIRE_DSN; Rails's environment and root are the defaults. Without this file,
# FIXWIRE_DSN alone is enough.
Fixwire.init(
  release: ENV.fetch("FIXWIRE_RELEASE", "shop@1.0.0"),
  traces_sample_rate: 1.0,
  # Trace headers go to our own inventory service, nowhere else.
  trace_propagation_targets: [ENV.fetch("INVENTORY_URL", "http://localhost:8081")]
)
