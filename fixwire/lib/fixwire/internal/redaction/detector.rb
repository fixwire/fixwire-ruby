# frozen_string_literal: true

module Fixwire
  module Internal
    module Redaction
      # Finds one kind of sensitive value. A cheap literal prefilter skips the
      # pattern on text that cannot match, and a validator rejects look-alikes.
      #
      # prefilter: substrings one of which must appear (in any case, unless
      # case_sensitive); none means always run. They are kept as one Regexp,
      # which Onigmo checks faster than a loop over the literals. pattern: a
      # regular expression whose group (0: the whole match) is masked, unless
      # scan, a scanner returning the spans, replaces it. validate: rejects a
      # matched text.
      Detector = Data.define(:name, :prefilter, :case_sensitive, :pattern, :group, :validate, :scan) do
        def initialize(name:, prefilter: [], case_sensitive: false, pattern: nil, group: 0, validate: nil, scan: nil)
          prefilter = Regexp.union(prefilter) if prefilter.is_a?(Array) && !prefilter.empty?
          super(name: name, prefilter: prefilter.is_a?(Regexp) ? prefilter : nil, case_sensitive: case_sensitive,
                pattern: pattern, group: group, validate: validate, scan: scan)
        end

        # Whether the prefilter lets text through to the pattern or scanner.
        def may_match?(text)
          prefilter.nil? || prefilter.match?(case_sensitive ? text.string : text.lower)
        end

        # The candidate spans, leftmost first, as [start, end] byte offsets.
        def spans(text)
          return scan.call(text) if scan

          out = []
          text.string.scan(pattern) do
            match = Regexp.last_match
            span = match.byteoffset(group)
            out << (span[0] ? span : match.byteoffset(0))
          end
          out
        end
      end
    end
  end
end
