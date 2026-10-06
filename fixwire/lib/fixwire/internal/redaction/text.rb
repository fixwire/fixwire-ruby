# frozen_string_literal: true

module Fixwire
  module Internal
    module Redaction
      # One string being searched, as valid UTF-8, with what several detectors
      # share. Offsets into it are byte offsets.
      class Text
        REPLACEMENT = "\uFFFD"

        attr_reader :string

        # The string as the server reads it after decoding JSON: valid UTF-8,
        # each invalid byte replaced by U+FFFD. Valid UTF-8 comes back as it
        # is; text in another encoding is converted.
        def self.utf8(string)
          case string.encoding
          when Encoding::UTF_8
            string.valid_encoding? ? string : scrub(string)
          when Encoding::BINARY, Encoding::US_ASCII
            scrub(string.dup.force_encoding(Encoding::UTF_8))
          else
            convert(string)
          end
        end

        # String#scrub hands over each invalid sequence whole (a truncated
        # character is one), but the server's decoder replaces every byte.
        def self.scrub(string)
          return string if string.valid_encoding?

          string.scrub { |bad| REPLACEMENT * bad.bytesize }
        end

        def self.convert(string)
          string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT)
        rescue EncodingError
          scrub(string.b.force_encoding(Encoding::UTF_8))
        end
        private_class_method :convert

        # A key as the server compares it: lower case, without "-", "_" and
        # spaces. String#downcase maps like the server's simple lower-casing
        # except for U+0130, which it turns into "i" and a combining dot.
        def self.key(string)
          utf8(string).tr("\u0130", "i").downcase.delete("-_ ")
        end

        # The start of valid UTF-8 text in at most limit bytes, cut on a
        # character boundary.
        def self.head(string, limit)
          return string if string.bytesize <= limit

          i = [limit, 0].max
          i -= 1 while i.positive? && string.getbyte(i).between?(0x80, 0xBF) # inside a character
          string.byteslice(0, i)
        end

        # Valid UTF-8 text in at most limit bytes: when it is longer (or was
        # cut already), it ends in "...", within the limit.
        def self.cut(string, limit, cut: false)
          return string if string.bytesize <= limit && !cut

          "#{head(string, limit - 3)}..."
        end

        def initialize(string)
          @string = string
        end

        # The bytes, for the scanners that read bytes as the server's do.
        def binary
          @binary ||= @string.b
        end

        # The string in lower case for the prefilters. They are ASCII, and on
        # the server only A-Z, U+0130 ("i") and the Kelvin sign ("k") lower-case
        # to ASCII, so only those are mapped.
        def lower
          @lower ||= begin
            lower = @string.downcase(:ascii)
            lower.include?("\u0130") || lower.include?("\u212A") ? lower.tr("\u0130\u212A", "ik") : lower
          end
        end

        # The standalone digit runs shaped like a card, an SSN or a TCKN, as
        # [start, end, shape] (see Scanners.number_runs).
        def numbers
          @numbers ||= Scanners.number_runs(binary)
        end
      end
    end
  end
end
