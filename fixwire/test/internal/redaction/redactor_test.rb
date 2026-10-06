# frozen_string_literal: true

require "minitest/autorun"
require "fixwire/internal/redaction"

module Fixwire
  module Internal
    module Redaction
      # Cases beyond the shared corpus. Every expected value is what the Fixwire
      # server's redaction answers for the same input (as JSON).
      class RedactorTest < Minitest::Test
        KELVIN = "\u212A"
        LONG_S = "\u017F"
        DOTTED_I = "\u0130"

        def test_default_is_shared_and_frozen
          assert_same Redactor.default, Redactor.create
          assert_predicate Redactor.default, :frozen?
          assert_equal ["", []], Redactor.default.mask("")
          assert_mask "nothing to see", [], "nothing to see"
        end

        def test_detectors_in_the_servers_order_with_ipv4_off
          assert_equal Redactor::DEFAULT_DETECTORS + ["ipv4"], Detectors::REGISTRY.map(&:name)
          assert_mask "client 203.0.113.9", [], "client 203.0.113.9"
          assert_raises(ArgumentError) { Detectors.named(["nope"]) }
        end

        def test_case_folding_as_the_server
          # The Kelvin sign folds to "k" in the case-insensitive detectors and
          # lower-cases to "k" for their prefilters.
          assert_mask "TO#{KELVIN}EN=[REDACTED:secret_assignment]", ["secret_assignment"], "TO#{KELVIN}EN=abcdefg"
          assert_mask "Account#{KELVIN}ey=[REDACTED:azure_storage_key]", ["azure_storage_key"],
                      "Account#{KELVIN}ey=#{"A" * 86}=="
          # The long s folds to "s" but stays itself in lower case, so the
          # prefilter needs another literal.
          assert_mask "pa#{LONG_S * 2}word=abcdefgh", [], "pa#{LONG_S * 2}word=abcdefgh"
          assert_mask "pa#{LONG_S * 2}word=[REDACTED:secret_assignment] pwd", ["secret_assignment"],
                      "pa#{LONG_S * 2}word=abcdefgh pwd"
          assert_mask "ba#{LONG_S}ic [REDACTED:http_auth] basic", ["http_auth"], "ba#{LONG_S}ic dXNlcjpwYXNz basic"
          # The long s is no ASCII word character: the word boundary before it
          # needs a word character on the left.
          assert_mask "x#{LONG_S}ecret=[REDACTED:secret_assignment] token", ["secret_assignment"],
                      "x#{LONG_S}ecret=abcdefgh token"
          assert_mask "#{LONG_S}ecret=abcdefgh token", [], "#{LONG_S}ecret=abcdefgh token"
          # U+0130 lower-cases to "i" but folds to nothing.
          assert_mask "BAS#{DOTTED_I}C abcdefghijkl1", [], "BAS#{DOTTED_I}C abcdefghijkl1"
        end

        def test_no_folding_beyond_the_servers
          # Ruby's "i" flag would take the sharp s for "ss"; the server does not.
          assert_mask "pa\u00DFword=abcdefgh pass", [], "pa\u00DFword=abcdefgh pass"
          assert_mask "PA\u00DFWORD=abcdefgh pass", [], "PA\u00DFWORD=abcdefgh pass"
        end

        def test_quantifiers_count_code_points
          assert_mask "password=ab\u{1F600}cd", [], "password=ab\u{1F600}cd"
          assert_mask "password=[REDACTED:secret_assignment]", ["secret_assignment"], "password=ab\u{1F600}cde"
        end

        def test_classes_and_boundaries_are_ascii
          # Other scripts' digits are no digits, and a vertical tab is no space.
          assert_mask "1#{"\u0663" * 11} [REDACTED:credit_card] \u0661\u0662\u0663", ["credit_card"],
                      "1#{"\u0663" * 11} 4111111111111111 \u0661\u0662\u0663"
          assert_mask "Bearer\vabcdefghijkl1 Bearer [REDACTED:http_auth]", ["http_auth"],
                      "Bearer\vabcdefghijkl1 Bearer abcdefghijkl1"
          assert_mask "token\v=abcdefgh token=[REDACTED:secret_assignment]", ["secret_assignment"],
                      "token\v=abcdefgh token=\vabcdefgh"
          # An accented letter is no word character (Ruby's \b says it is).
          assert_mask "\u00E9[REDACTED:email]\u00E9", ["email"], "\u00E9ada@example.com\u00E9"
          assert_mask "\u00E9[REDACTED:credit_card] \u00FC[REDACTED:credit_card]", %w[credit_card credit_card],
                      "\u00E94111111111111111 \u00FC4111111111111111"
          assert_mask "x\u00E9[REDACTED:aws_access_key]", ["aws_access_key"], "x\u00E9#{%w[AKIA IOSFODNN7EXAMPLE].join}"
          assert_mask "\u00FC@example.com caf\u00E9@example.com", [], "\u00FC@example.com caf\u00E9@example.com"
        end

        def test_scanners_as_the_servers_patterns
          # Split, so no secret scanner takes the test for a leak.
          jwt = ["eyJ", "hbGciOiJIUzI1NiJ9.", "eyJ", "zdWIiOiIxMjM0NTY3ODkwIn0.", "dozjgNryP4J3jVmNHl0w5N"].join

          assert_mask "-[REDACTED:jwt]", ["jwt"], "-#{jwt}"
          # Overlapping addresses: the first wins.
          assert_mask "[REDACTED:email]@c.de", ["email"], "a@b.co@c.de"
          assert_mask "dial 1http://u:p@h and x_http://u:p@h and a+b://u:[REDACTED:url_credentials]@h",
                      ["url_credentials"], "dial 1http://u:p@h and x_http://u:p@h and a+b://u:p@h"
        end

        def test_invalid_utf8_is_searched_as_the_server_decodes_it
          assert_mask "user [REDACTED:email] \uFFFD", ["email"], "user ada@example.com \xFF"
          # The text comes back as valid UTF-8 even without findings.
          assert_mask "plain \uFFFD text", [], "plain \xFF text"
          # Each invalid byte is one U+FFFD (String#scrub would write one for a
          # truncated character), surrogates included.
          assert_mask "\uFFFD\uFFFD [REDACTED:email] \u3042", ["email"], "\xE3\x81 ada@example.com \xE3\x81\x82"
          assert_mask "\uFFFD\uFFFD\uFFFDtoken=[REDACTED:secret_assignment]", ["secret_assignment"],
                      "\xED\xA0\x80token=abcdefgh"
          assert_walk({ "[REDACTED:email]\uFFFD" => "\uFFFD", "k" => "\uFFFD" }, 1,
                      { "ada@example.com\xFE" => "\xFF", "k" => "\xC0" })
        end

        def test_other_encodings_are_read_as_utf8
          masked, findings = Redactor.default.mask("user ada@example.com \xFF".b)

          assert_equal ["user [REDACTED:email] \uFFFD", ["email"]], [masked, findings]
          assert_equal Encoding::UTF_8, masked.encoding
          assert_mask "caf\u00E9 [REDACTED:email]", ["email"], "caf\u00E9 ada@example.com".encode(Encoding::ISO_8859_1)
          assert_mask "plain", [], "plain".encode(Encoding::US_ASCII)
        end

        def test_hostile_inputs_take_linear_time
          hostile_inputs.each_with_index do |s, i|
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            masked, = Redactor.default.mask(s)
            ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

            assert_operator ms, :<, 500, "input #{i}"
            refute_match(/\A\[REDACTED:[a-z_]+\]\z/, masked, "input #{i}")
          end
        end

        def test_many_findings_in_one_text
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          masked, findings = Redactor.default.mask("ada@example.com " * 6000)

          assert_operator (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000, :<, 500
          assert_equal 6000, findings.size
          assert_equal "[REDACTED:email] " * 6000, masked
        end

        def test_sensitive_keys
          assert_walk(
            { "Auth" => "[Filtered]", "auth" => "[Filtered]", "author" => "c", "X-CSRF-Token" => "[Filtered]",
              "max_tokens" => 5, "input_tokens" => "x", "token_count" => "y", "usage_token" => "z",
              "empty_token" => "", "none_token" => nil, "db_password" => "[Filtered]" },
            3,
            { "Auth" => "b", "auth" => "a", "author" => "c", "X-CSRF-Token" => "q",
              "max_tokens" => 5, "input_tokens" => "x", "token_count" => "y", "usage_token" => "z",
              "empty_token" => "", "none_token" => nil, "db_password" => "[Filtered]" }
          )
          # Keys lower-case as the server's: U+0130 to "i", the Kelvin sign to "k".
          assert_walk(
            { "CREDENT#{DOTTED_I}AL" => "[Filtered]", "pa#{LONG_S * 2}word" => "y", "TO#{KELVIN}EN" => "[Filtered]" },
            2,
            { "CREDENT#{DOTTED_I}AL" => "x", "pa#{LONG_S * 2}word" => "y", "TO#{KELVIN}EN" => "z" }
          )
        end

        def test_custom_keys_replace_the_defaults
          input = { "x api key" => "s", "apikey" => "t", "password" => "u", "auth" => "v" }

          assert_equal [{ "x api key" => "[Filtered]", "apikey" => "t", "password" => "u", "auth" => "[Filtered]" }, 2],
                       Redactor.create(["X-Api_Key"]).walk(input)
          assert_equal [{ "password" => "u", "auth" => "[Filtered]" }, 1],
                       Redactor.create([]).walk({ "password" => "u", "auth" => "v" })
          # Configured keys are normalized like the keys they are compared with.
          input = { "passion" => "a", "PASS#{DOTTED_I}ON_fruit" => "b", "pass" => "c" }

          assert_equal [{ "passion" => "[Filtered]", "PASS#{DOTTED_I}ON_fruit" => "[Filtered]", "pass" => "c" }, 2],
                       Redactor.create(["Pass#{DOTTED_I}ON"]).walk(input)
        end

        def test_renamed_keys_are_numbered_in_code_point_order
          # U+FFFF sorts before U+1F600 by code point (not in UTF-16).
          assert_walk(
            { "http://u:[REDACTED:url_credentials]@h" => "[Filtered]",
              "http://u:[REDACTED:url_credentials]@h (3)" => 2,
              "http://u:[REDACTED:url_credentials]@h (2)" => 1 },
            3,
            { "http://u:[REDACTED:url_credentials]@h" => 3, "http://u:\u{1F600}x@h" => 2, "http://u:\uFFFFx@h" => 1 }
          )
          assert_walk({ "[REDACTED:email] (3)" => 2, "[REDACTED:email] (2)" => 1, "[REDACTED:email]" => 0 }, 2,
                      { "b@example.com" => 2, "a@example.com" => 1, "[REDACTED:email]" => 0 })
          # Keys other than strings hold data too.
          assert_walk({ "[REDACTED:credit_card]" => "card as key" }, 1, { 4_111_111_111_111_111 => "card as key" })
          # Numbering goes past the names other keys hold.
          assert_walk({ "[REDACTED:email]" => 1, "[REDACTED:email] (3)" => 2, "[REDACTED:email] (2)" => 0 }, 2,
                      { "a@b.co" => 1, "c@d.co" => 2, "[REDACTED:email] (2)" => 0 })
        end

        # Request headers are keys an attacker picks: thousands masking alike are numbered in one pass.
        def test_many_keys_masking_alike_are_numbered_quickly
          input = (1..6000).to_h { |i| ["user-#{format("%04d", i)}@example.com", i] }
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          out, count = Redactor.default.walk(input)

          assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
          assert_equal 6000, count
          assert_equal [1, 2, 6000], out.values_at("[REDACTED:email]", "[REDACTED:email] (2)", "[REDACTED:email] (6000)")
        end

        def test_typed_attributes_and_pairs
          assert_walk(
            { "password" => { "type" => "string", "value" => "[Filtered]" },
              "token" => { "type" => "string", "value" => "[Filtered]" },
              "secret" => "[Filtered]",
              "headers" => [["Authorization", "[Filtered]"], ["Cookie", ""], ["Accept", "[REDACTED:email]"]],
              "pair" => ["password", "[Filtered]"],
              "map" => { "a" => "password", "b" => "x" } },
            5,
            { "password" => { "type" => "int", "value" => 5 },
              "token" => { "type" => "string", "value" => "[Filtered]" },
              "secret" => { "type" => "x", "value" => nil },
              "headers" => [["Authorization", "Bearer abc"], ["Cookie", ""], ["Accept", "a@b.co"]],
              "pair" => ["password", "[Filtered]"],
              "map" => { "a" => "password", "b" => "x" } }
          )
          # A typed attribute gains a type; nothing else in it is walked.
          assert_walk(
            { "apikey" => { "value" => "[Filtered]", "type" => "string" }, "cvv" => "[Filtered]", "ssn" => "[Filtered]",
              "secret" => { "type" => "string", "value" => "[Filtered]", "note" => "ada@example.com" } },
            4,
            { "apikey" => { "value" => "k" }, "cvv" => ["123"], "ssn" => 123_456_789,
              "secret" => { "type" => "t", "value" => "s", "note" => "ada@example.com" } }
          )
        end

        def test_symbols_count_as_the_strings_they_name
          assert_walk(
            { password: "[Filtered]", "[REDACTED:email]" => 1, list: ["[REDACTED:email]", :plain],
              pair: [:Cookie, "[Filtered]"], token: { type: "string", value: "[Filtered]" },
              apikey: { value: "[Filtered]", type: "string" } },
            6,
            { password: "x", "a@b.co": 1, list: %i[ada@example.com plain], pair: [:Cookie, "v"],
              token: { type: "int", value: 5 }, apikey: { value: "k" } }
          )
        end

        def test_input_is_never_changed
          input = deep_freeze({ "user" => { "email" => "ada@example.com", "tags" => [%w[password x]] },
                                "a@b.co" => [1, { "token" => { "type" => "int", "value" => 5 } }],
                                "clean" => { "n" => 1 } })
          copy = Marshal.load(Marshal.dump(input))
          out, count = Redactor.default.walk(input)

          assert_equal 4, count
          assert_equal copy, input
          assert_equal({ "n" => 1 }, out["clean"])
          refute_same input["clean"], out["clean"]
        end

        def test_other_values_stay
          object = Object.new

          assert_walk([1, 2.5, true, false, nil, object, "[REDACTED:email]"], 1,
                      [1, 2.5, true, false, nil, object, "ada@example.com"])
        end

        def test_containers_deeper_than_the_limit_are_left_alone
          deep = (1..600).reduce("ada@example.com") { |v, _| [v] }

          assert_walk(deep, 0, deep)
          shallow = (1..500).reduce("ada@example.com") { |v, _| [v] }
          out, count = Redactor.default.walk(shallow)

          assert_equal 1, count
          assert_equal "[REDACTED:email]", out.flatten.first
        end

        private

        def assert_mask(masked, findings, input)
          assert_equal [masked, findings], Redactor.default.mask(input)
        end

        def assert_walk(expected, count, input)
          assert_equal [expected, count], Redactor.default.walk(input)
        end

        def deep_freeze(value)
          case value
          when Hash then value.each_value { |v| deep_freeze(v) }
          when Array then value.each { |v| deep_freeze(v) }
          end
          value.freeze
        end

        # About 100 KB each; a backtracking pattern would take seconds.
        def hostile_inputs
          begin_line = "-----BEGIN RSA PRIVATE KEY-----"
          [
            "#{"a." * 50_000}://", "#{begin_line}\nMIIE\n" * 3000, "-----BEGIN #{"A" * 100}" * 1000,
            "a://b:#{":" * 100_000}", "a://b:c" * 14_000, "1://" * 25_000, "1-" * 50_000, "1 " * 50_000,
            "#{"a." * 50_000}#{"@" * 1000}", "a@" * 50_000, "xoxb-#{"a" * 300}" * 300, "ghp_" * 25_000,
            "ghp_#{"a" * 100_000}", "pwd: abc " * 11_000, "password#{" " * 100_000}", "Bearer " * 14_000,
            "AB12 " * 20_000, "+1 2 3 " * 14_000, "eyJaaaaaaaaaa." * 7000, "-eyJ" * 25_000,
            "-eyJaaaaaaaa.eyJ#{"-eyJ" * 25_000}"
          ]
        end
      end
    end
  end
end
