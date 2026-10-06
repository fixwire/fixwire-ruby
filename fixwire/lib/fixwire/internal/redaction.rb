# frozen_string_literal: true

module Fixwire
  module Internal
    # On-device redaction: the Fixwire server's detectors and JSON rules, so
    # secrets and personal data are masked before they leave the process.
    module Redaction
      # Replaces the value of a sensitive key.
      FILTERED = "[Filtered]"
    end
  end
end

require_relative "redaction/text"
require_relative "redaction/validators"
require_relative "redaction/scanners"
require_relative "redaction/detector"
require_relative "redaction/detectors"
require_relative "redaction/walker"
require_relative "redaction/redactor"
