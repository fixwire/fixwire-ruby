# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "fixwire/internal/redaction"

module Fixwire
  module Internal
    module Redaction
      # The shared corpus of the Fixwire server's redaction (a copy of
      # pkg/redact/testdata/vectors.json in fixwire/fixwire, kept identical):
      # the same defaults, the same masked strings and findings, the same
      # masked documents and counts.
      class VectorsTest < Minitest::Test
        VECTORS_PATH = File.join(__dir__, "vectors.json")

        def test_defaults_match_the_server
          assert_equal vectors["detectors"], Redactor::DEFAULT_DETECTORS
          assert_equal vectors["sensitive_keys"], Redactor::DEFAULT_SENSITIVE_KEYS
        end

        def test_strings
          refute_empty vectors["strings"]
          vectors["strings"].each do |c|
            masked, findings = Redactor.default.mask(expand(c["input"]))

            assert_equal expand(c["masked"]), masked, c["name"]
            assert_equal c["findings"], findings, c["name"]
          end
        end

        def test_documents
          refute_empty vectors["documents"]
          vectors["documents"].each do |c|
            masked, count = Redactor.default.walk(expand(c["input"]))

            assert_equal expand(c["masked"]), masked, c["name"]
            assert_equal c["count"], count, c["name"]
          end
        end

        private

        def vectors
          @vectors ||= JSON.parse(File.read(VECTORS_PATH))
        end

        # Each "{{name}}" with its fixture's parts joined (the parts keep
        # secret-looking values out of the file).
        def fixtures
          @fixtures ||= vectors["fixtures"].to_h { |name, parts| ["{{#{name}}}", parts.join] }
        end

        def expand(value)
          case value
          when String then fixtures.reduce(value) { |s, (name, fixture)| s.gsub(name, fixture) }
          when Array then value.map { |v| expand(v) }
          when Hash then value.to_h { |k, v| [expand(k), expand(v)] }
          else value
          end
        end
      end
    end
  end
end
