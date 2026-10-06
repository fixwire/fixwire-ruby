# frozen_string_literal: true

module Fixwire
  module Internal
    module Redaction
      # Masks secrets and personal data on the device before anything is sent,
      # with the same output as the Fixwire server's redaction (proven by the
      # shared corpus pkg/redact/testdata/vectors.json).
      #
      # Detectors run in a fixed order; a cheap prefilter skips each one on
      # text that cannot match, and validators (Luhn, mod-97, checksums) reject
      # look-alikes so trace ids, hashes and timestamps survive. Immutable and
      # safe to share between threads.
      #
      # Text is searched as the server receives it: valid UTF-8, each invalid
      # byte as U+FFFD (see Text.utf8). What comes out is valid UTF-8.
      class Redactor
        FILTERED = Redaction::FILTERED

        # The detectors on by default, in the server's order: all but ipv4 (in
        # error messages IP addresses are usually servers worth seeing).
        DEFAULT_DETECTORS = %w[
          private_key aws_access_key gcp_api_key azure_storage_key github_token stripe_key slack_token slack_webhook
          anthropic_key openai_key jwt fixwire_secret_key url_credentials http_auth secret_assignment email credit_card
          iban us_ssn tr_tckn phone
        ].freeze

        # Key fragments whose values are always filtered whole.
        DEFAULT_SENSITIVE_KEYS = %w[
          password passwd pwd secret apikey accesskey token credential privatekey authorization cookie sessionid csrf
          xsrf cvv cvc ssn creditcard cardnumber
        ].freeze

        private_class_method :new

        # The redactor with the default detectors and sensitive keys.
        def self.default
          DEFAULT
        end

        # A redactor with the default detectors. Sensitive keys, when given,
        # replace the defaults, compared like the server does (lower case,
        # without "-", "_" and spaces).
        def self.create(sensitive_keys = nil)
          return DEFAULT if sensitive_keys.nil?

          new(Detectors.named(DEFAULT_DETECTORS), sensitive_keys.map { |k| Text.key(k.to_s) })
        end

        def initialize(detectors, keys)
          @detectors = detectors.freeze
          @keys = keys.freeze
          freeze
        end

        # Masks the findings in a string: each becomes "[REDACTED:<detector>]",
        # as the server writes it. Returns the masked text and each finding's
        # detector, leftmost first.
        def mask(string)
          text = Text.new(Text.utf8(string))
          found = find(text)
          return [text.string, []] if found.empty?

          [replace(text.string, found), found.map(&:last)]
        end

        # Masks every string in a JSON-like value (Hash, Array, String, Symbol,
        # numbers, true, false, nil) and filters the values of sensitive keys,
        # by the server's rules. Returns a new value, which shares what did not
        # change with the input, and the number of values masked.
        def walk(value)
          walker = Walker.new(self)
          [walker.value(value), walker.count]
        end

        # Whether the value under a key must be filtered whole. Keys that count
        # model tokens are no tokens: gen_ai.usage.input_tokens, max_tokens.
        def sensitive?(key)
          k = Text.key(key)
          return true if k == "auth"

          @keys.any? { |fragment| k.include?(fragment) && (fragment != "token" || !token_count?(k)) }
        end

        private

        # The non-overlapping findings, as [start, end, detector] sorted by
        # start; when two overlap, the earlier detector wins. A pattern that
        # times out (a Regexp.timeout set by the application) masks the whole
        # text, so a failure never lets a value through.
        def find(text)
          found = []
          @detectors.each do |detector|
            next unless detector.may_match?(text)

            added = accept(detector, detector.spans(text), found, text)
            found = (found + added).sort_by!(&:first) unless added.empty?
          rescue Regexp::TimeoutError
            return [[0, text.string.bytesize, detector.name]]
          end
          found
        end

        # One detector's spans that pass its validator and overlap neither an
        # earlier detector's findings nor its own. Spans come leftmost first,
        # so one pass checks them.
        def accept(detector, spans, found, text)
          added = []
          last_end = -1
          k = 0
          spans.each do |start, stop|
            next if start < last_end
            next if detector.validate && !detector.validate.call(text.string.byteslice(start, stop - start))

            k += 1 while k < found.size && found[k][1] <= start
            next if k < found.size && found[k][0] < stop

            added << [start, stop, detector.name]
            last_end = stop
          end
          added
        end

        def replace(string, found)
          out = String.new(capacity: string.bytesize + (found.size * 24), encoding: Encoding::UTF_8)
          last = 0
          found.each do |start, stop, name|
            out << string.byteslice(last, start - last) << "[REDACTED:" << name << "]"
            last = stop
          end
          out << string.byteslice(last, string.bytesize - last)
        end

        def token_count?(key)
          key.end_with?("tokens") || key.include?("tokencount") || key.include?("usage")
        end

        DEFAULT = new(Detectors.named(DEFAULT_DETECTORS), DEFAULT_SENSITIVE_KEYS)
        private_constant :DEFAULT
      end
    end
  end
end
