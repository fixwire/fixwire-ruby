# frozen_string_literal: true

module Fixwire
  module Internal
    module Redaction
      # Hand-written scanners. They read bytes as the server's do: every byte
      # they test for is ASCII, so a multi-byte character never matches.
      # Spans are [start, end] byte offsets, leftmost first.
      #
      # Three of them stand for server patterns (private keys, URL
      # credentials, JWTs): they find the same matches in linear time, where
      # a backtracking engine would retry each start to the end of the text.
      module Scanners
        # The shapes of a number run (bits).
        CARD = 1
        SSN = 2
        TCKN = 4

        # How every card, TCKN or SSN run starts: a digit and ten more bytes of
        # digits, spaces and dashes.
        NUMBER_HINT = /[0-9][0-9 -]{10}/
        NOT_NUMBER = /[^0-9 -]/
        NUMBER_RUN = /(?<![0-9A-Za-z_])[0-9]+(?:([ -])[0-9]+(?:\1[0-9]+)*)?/
        SSN_RUN = /\A[0-9]{3}-[0-9]{2}-[0-9]{4}\z/
        # A run of local-part characters from its start (group 1 without
        # leading dots and dashes), "@", and a domain run that, without its
        # trailing dots and dashes (group 2), ends in a dot and a TLD of 2 to
        # 24 letters after something. The lookbehind tries each run once.
        EMAIL = /
          (?<![0-9A-Za-z_.%+-])[.-]*([0-9A-Za-z_%+][0-9A-Za-z_.%+-]*)
          @(?=([0-9A-Za-z.-]+\.[A-Za-z]{2,24})[.-]*(?![0-9A-Za-z.-]))
        /x
        NOT_KEY_TYPE = /[^A-Z ]/
        KEY_LABEL = "PRIVATE KEY-----"
        # The server's pattern from "://" on; the password is group 1.
        CREDENTIALS = %r{://[^\t\n\f\r /?#@:]*:([^\t\n\f\r /?#@]+)@}
        NOT_SCHEME = /[^0-9A-Za-z+.-]/
        SCHEME_INNER_START = /[+.-][A-Za-z]/
        JWT_START = /(?<![0-9A-Za-z_])eyJ/
        NOT_JWT = /[^0-9A-Za-z_-]/

        DOT = 46
        SPACE = 32

        module_function

        def word?(byte)
          letter?(byte) || byte == 95 || (!byte.nil? && byte.between?(48, 57))
        end

        def letter?(byte)
          !byte.nil? && (byte.between?(65, 90) || byte.between?(97, 122))
        end

        # The runs of digits, optionally split by single spaces or dashes (one
        # kind per run), that stand alone as words: a run starts at a digit
        # after no word character and counts only when no word character
        # follows it. Only runs shaped like a card, an SSN or a TCKN are kept,
        # as [start, end, shape].
        #
        # Runs are made of digits, spaces and dashes, so no run crosses the
        # edge of a stretch of them, and only stretches with a NUMBER_HINT are
        # read (with the byte before, for the word boundary).
        def number_runs(bytes)
          out = []
          # The shortest run kept, an SSN, has nine digits.
          return out if bytes.count("0-9") < 9

          from = 0
          while (hint = bytes.byteindex(NUMBER_HINT, from))
            start = (bytes.byterindex(NOT_NUMBER, hint) || -1) + 1
            from = bytes.byteindex(NOT_NUMBER, hint) || bytes.bytesize
            before = start.zero? ? 0 : start - 1
            area = bytes.byteslice(before, from - before)
            area_runs(bytes, area, before, out) if may_hold_run?(area)
          end
          out
        end

        # A card has 13 digits, a TCKN 11, an SSN 9 apart by dashes.
        def may_hold_run?(area)
          digits = area.count("0-9")
          digits >= 11 || (digits >= 9 && area.include?("-"))
        end

        def area_runs(bytes, area, offset, out)
          area.scan(NUMBER_RUN) do
            match = Regexp.last_match
            start, stop = match.byteoffset(0)
            # Cards are 13 to 37 bytes with separators, SSNs and TCKNs 11.
            next if stop - start < 11 || stop - start > 37 || word?(bytes.getbyte(offset + stop))

            shape = run_shape(area.byteslice(start, stop - start), match[1])
            out << [offset + start, offset + stop, shape] unless shape.zero?
          end
        end

        def run_shape(run, sep)
          digits = sep ? run.bytesize - run.count(sep) : run.bytesize
          shape = digits.between?(13, 19) ? CARD : 0
          shape |= SSN if sep == "-" && SSN_RUN.match?(run)
          shape |= TCKN if sep.nil? && digits == 11
          shape
        end

        # The number runs of one shape that the block accepts.
        def number_spans(text, shape)
          text.numbers.filter_map do |start, stop, kind|
            [start, stop] if kind.anybits?(shape) && yield(text.binary.byteslice(start, stop - start))
          end
        end

        def card_spans(text)
          number_spans(text, CARD) { |run| Validators.card?(run) }
        end

        def ssn_spans(text)
          number_spans(text, SSN) { |run| Validators.ssn?(run) }
        end

        def tckn_spans(text)
          number_spans(text, TCKN) { |run| Validators.tckn?(run) }
        end

        # As the server: grows outwards from each "@" over the characters an
        # address may hold, and keeps it if the domain ends in a dotted,
        # alphabetic TLD. A match ends at its "@", so the next local part may
        # be in this domain: spans may overlap, and the caller keeps the first.
        def email_spans(text)
          out = []
          text.binary.scan(EMAIL) do
            match = Regexp.last_match
            out << [match.byteoffset(1)[0], match.byteoffset(2)[1]]
          end
          out
        end

        # The server's
        # -----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----
        # each BEGIN line with the first END line after it.
        def private_key_spans(text)
          bytes = text.binary
          out = []
          from = 0
          while (begin_at = bytes.byteindex("-----BEGIN ", from))
            head = key_label_end(bytes, begin_at + 11)
            if head.nil?
              from = begin_at + 1
              next
            end
            stop = key_end(bytes, head)
            break if stop.nil? # a later BEGIN line finds no END line either

            out << [begin_at, stop]
            from = stop
          end
          out
        end

        def key_end(bytes, from)
          line = bytes.byteindex("-----END ", from)
          while line
            stop = key_label_end(bytes, line + 9)
            return stop if stop

            line = bytes.byteindex("-----END ", line + 1)
          end
        end

        # The end of (?:[A-Z ]+ )?PRIVATE KEY----- at from, or nil. "PRIVATE
        # KEY" can only end the run of capitals and spaces from there, so there
        # is one place to look.
        def key_label_end(bytes, from)
          label = (bytes.byteindex(NOT_KEY_TYPE, from) || bytes.bytesize) - 11
          return if label < from || bytes.byteslice(label, 16) != KEY_LABEL
          # The type before the label needs a letter or space and then a space.
          return if label > from && (label < from + 2 || bytes.getbyte(label - 1) != SPACE)

          label + 16
        end

        # The password of the server's
        # \b[A-Za-z][A-Za-z0-9+.\-]*://[^\s/?#@:]*:([^\s/?#@]+)@
        # CREDENTIALS finds each "://" with the rest of a match after it; every
        # start in the scheme before it shares that rest, so one start is
        # enough. What CREDENTIALS takes holds no other "://" and no scheme.
        def url_credential_spans(text)
          bytes = text.binary
          out = []
          from = 0
          bytes.scan(CREDENTIALS) do
            match = Regexp.last_match
            sep, stop = match.byteoffset(0)
            next unless scheme?(bytes, sep, from)

            out << match.byteoffset(1)
            from = stop
          end
          out
        end

        # Whether a letter at a word boundary starts a scheme that runs to sep,
        # not before from (the end of the last match).
        def scheme?(bytes, sep, from)
          return false if sep <= from

          before = bytes.byterindex(NOT_SCHEME, sep - 1)
          start = before.nil? || before < from ? from : before + 1
          return false if start >= sep
          return true if letter?(bytes.getbyte(start)) && (start.zero? || !word?(bytes.getbyte(start - 1)))

          # Inside the run only "+", "." and "-" are no word characters.
          SCHEME_INNER_START.match?(bytes.byteslice(start, sep - start))
        end

        # The server's \beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}.
        # A segment holds no ".", so it runs to the end of its run of segment
        # characters, and every start in one run ends its first segment at the
        # same place: one failed start rules out the rest of its run.
        def jwt_spans(text)
          bytes = text.binary
          out = []
          from = 0
          while (start = bytes.byteindex(JWT_START, from))
            first = segment_end(bytes, start + 3)
            stop = first - start - 3 >= 8 && bytes.getbyte(first) == DOT && jwt_rest(bytes, first + 1)
            if stop
              out << [start, stop]
              from = stop
            else
              from = first
            end
          end
          out
        end

        def jwt_rest(bytes, start)
          return unless bytes.byteslice(start, 3) == "eyJ"

          second = segment_end(bytes, start + 3)
          return unless second - start - 3 >= 8 && bytes.getbyte(second) == DOT

          third = segment_end(bytes, second + 1)
          third if third - second - 1 >= 8
        end

        def segment_end(bytes, from)
          bytes.byteindex(NOT_JWT, from) || bytes.bytesize
        end
      end
    end
  end
end
