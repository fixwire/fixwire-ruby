# frozen_string_literal: true

module Fixwire
  module Internal
    module Redaction
      # Checks that reject look-alikes (Luhn, mod-97, check digits), so trace
      # ids, hashes and timestamps survive. Each takes the matched text.
      module Validators
        CARD_PREFIXES = %w[4 51 52 53 54 55 2221 2720 34 37 6011 65 35 36 38 300 305 62].freeze
        IBAN_CHARS = /\A[0-9A-Z]+\z/

        module_function

        # Rejects values a scrubber already replaced.
        def unmasked?(value)
          !value.start_with?("[REDACTED") && value != FILTERED
        end

        # Tells a token from a word after "basic": it has a digit, a base64
        # symbol, or capitals past its first letter ("dXNlcjpwYXNz", but not
        # "Authentication"). The server reads the bytes after the first.
        def credential?(value)
          return true if value.match?(%r{[0-9+/=]})

          rest = value.b.byteslice(1, value.bytesize)
          rest.match?(/[A-Z]/) && rest.match?(/[a-z]/)
        end

        # Checks the length, a known issuer prefix and the Luhn sum.
        def card?(run)
          digits = run.delete("^0-9")
          return false unless digits.bytesize.between?(13, 19) && CARD_PREFIXES.any? { |p| digits.start_with?(p) }

          luhn?(digits)
        end

        # A while loop: hostile text can hold a card look-alike every 17 bytes.
        def luhn?(digits)
          sum = 0
          i = digits.bytesize - 1
          double = false
          while i >= 0
            n = digits.getbyte(i) - 48
            n = n > 4 ? (2 * n) - 9 : 2 * n if double
            sum += n
            double = !double
            i -= 1
          end
          (sum % 10).zero?
        end

        # Checks the length (15 to 34) and the mod-97 checksum of the decimal
        # number the characters spell (A = 10 ... Z = 35), read from the fifth
        # character round to the fourth.
        def iban?(match)
          s = match.delete(" ")
          return false unless s.bytesize.between?(15, 34) && IBAN_CHARS.match?(s)

          mod97(s, 0, 4, mod97(s, 4, s.bytesize, 0)) == 1
        end

        # The remainder after reading bytes from...to of text on after rem. A
        # while loop: hostile text can hold an IBAN look-alike every 40 bytes.
        def mod97(text, from, to, rem)
          i = from
          while i < to
            byte = text.getbyte(i)
            rem = byte < 65 ? ((rem * 10) + byte - 48) % 97 : ((rem * 100) + byte - 55) % 97
            i += 1
          end
          rem
        end

        # Rejects numbers the US never issues.
        def ssn?(run)
          area = run.byteslice(0, 3)
          area != "000" && area != "666" && !area.start_with?("9") &&
            run.byteslice(4, 2) != "00" && run.byteslice(7, 4) != "0000"
        end

        # Checks the Turkish identity number's two check digits.
        def tckn?(run)
          return false if run.bytesize != 11 || run.start_with?("0")

          d = run.bytes.map { |byte| byte - 48 }
          odd = d[0] + d[2] + d[4] + d[6] + d[8]
          even = d[1] + d[3] + d[5] + d[7]
          ((odd * 7) - even) % 10 == d[9] && d[0, 10].sum % 10 == d[10]
        end

        # Wants an international number of 8 to 15 digits.
        def phone?(match)
          match.count("0-9").between?(8, 15)
        end
      end
    end
  end
end
