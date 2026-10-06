# frozen_string_literal: true

module Fixwire
  module Internal
    module Redaction
      # The detectors of the Fixwire server's redaction, in its order, with the
      # same patterns, prefilters, validators and scanners.
      #
      # The server's patterns are ASCII-only, but Ruby's \b and \s are not
      # (\b takes accented letters as word characters, \s takes the vertical
      # tab), so digits are [0-9], whitespace is [\t\n\f\r ] and the word
      # boundary is spelled out as lookarounds on ASCII word characters.
      # Nothing ignores case through the "i" flag, which also matches the sharp
      # s (U+00DF) for "ss": where the server ignores case, each letter is a
      # class, with the Kelvin sign next to "k" and the long s next to "s" as
      # the server folds them. Atomic groups stand where the next token cannot
      # match what they took: the same matches without backtracking.
      #
      # On UTF-8 text the patterns count characters, as the server's count
      # code points.
      module Detectors
        IPV4 = "ipv4"

        WORD = "[0-9A-Za-z_]"
        # The server's word boundary before a word character.
        START = "(?<!#{WORD})".freeze
        # The server's word boundary after a word character.
        FINISH = "(?!#{WORD})".freeze
        # The server's word boundary where either side may be a word character.
        EDGE = "(?:(?<=#{WORD})(?!#{WORD})|(?<!#{WORD})(?=#{WORD}))".freeze
        SPACE = "[\\t\\n\\f\\r ]"
        # The letters the server's case-insensitive classes add to [A-Za-z].
        FOLDED = "\u017F\u212A"
        FOLDS = { "k" => "\u212A", "s" => "\u017F" }.freeze

        # A pattern for lower-case letters in any case, as the server folds
        # them: "k" also matches the Kelvin sign and "s" the long s.
        def self.any_case(letters)
          letters.each_char.map { |c| "[#{c}#{c.upcase}#{FOLDS.fetch(c, "")}]" }.join
        end

        AWS_ACCESS_KEY = /#{START}(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}#{FINISH}/
        GCP_API_KEY = /#{START}AIza[0-9A-Za-z_-]{35}/
        AZURE_STORAGE_KEY = %r{#{any_case("accountkey")}=([A-Za-z0-9+/#{FOLDED}]{86}==)}
        GITHUB_TOKEN = /#{START}(?:gh[pousr]_(?>[A-Za-z0-9]{36,255})|github_pat_(?>[A-Za-z0-9_]{60,255}))#{FINISH}/
        STRIPE_KEY = %r{#{START}(?:(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,247}|whsec_[A-Za-z0-9+/=]{24,})}
        SLACK_TOKEN = /#{START}xox[abposr]-[0-9A-Za-z-]{10,250}#{EDGE}/
        SLACK_WEBHOOK = %r{https://hooks\.slack\.com/services/T(?>[A-Z0-9]+)/B(?>[A-Z0-9]+)/[A-Za-z0-9]+}
        ANTHROPIC_KEY = /#{START}sk-ant-(?:api|admin)[0-9]{2}-[A-Za-z0-9_-]{80,}/
        OPENAI_KEY = /#{START}sk-(?:(?:proj|svcacct|admin)-[A-Za-z0-9_-]{40,}|[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20})/
        FIXWIRE_SECRET_KEY = /#{START}[a-z]{2,4}_sk_(?:live|test)_[0-9A-Za-z]{38}#{FINISH}/
        HTTP_AUTH = %r{
          #{START}(?:#{any_case("bearer")}|#{any_case("basic")})(?>#{SPACE}+)
          ((?>[A-Za-z0-9._~+/#{FOLDED}-]{12,})=*)
        }x
        # A value given to a secret's name, in text, config and URLs. The name
        # may end a longer one (access_token, client_secret, csrfToken,
        # PHPSESSID, X-Amz-Signature); an OAuth code counts in a query or
        # fragment only. At most one way of reading a name can be followed by
        # the separator, so the name is atomic too, and every quantifier after
        # it is: each start costs the name and the spaces after it, which no
        # other start reads again. The timeout is the backstop: text it stops
        # is sent as [Filtered], never unmasked.
        SECRET_ASSIGNMENT = Regexp.new(<<~PATTERN, Regexp::EXTENDED, timeout: 1.0)
          (?>#{any_case("password")}|#{any_case("passwd")}|#{any_case("pwd")}
            |#{any_case("secret")}(?:[_-]?#{any_case("key")})?|#{any_case("private")}[_-]?#{any_case("key")}
            |#{any_case("token")}|#{any_case("api")}[_-]?#{any_case("key")}|#{any_case("access")}[_-]?#{any_case("key")}
            |#{any_case("credential")}#{any_case("s")}?|#{any_case("sess")}(?:#{any_case("ion")})?[_-]?#{any_case("id")}
            |#{any_case("sig")}(?:#{any_case("nature")})?|[?&\\#]#{any_case("code")})
          (?>["']?)(?>#{SPACE}*)[:=](?>#{SPACE}*)(?>["']?)
          ((?>[^\\t\\n\\f\\r\\ "',;&]{6,}))
        PATTERN
        # The boundary is checked after the first letter: a pattern that starts
        # with a class lets Onigmo skip ahead to candidates.
        IBAN = /[A-Z](?<!#{WORD}[A-Z])[A-Z][0-9]{2}(?:\ ?[A-Z0-9]{4}){2,7}(?:\ ?[A-Z0-9]{1,3})?#{FINISH}/x
        PHONE = /\+[0-9](?:[ .\-()]?[0-9]){7,14}#{FINISH}/
        OCTET = "(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
        IPV4_ADDRESS = /#{START}(?:#{OCTET}\.){3}#{OCTET}#{FINISH}/

        # A case-sensitive detector.
        def self.exact(name, prefilter, **)
          Detector.new(name: name, prefilter: prefilter, case_sensitive: true, **)
        end

        # Every detector, in the server's order.
        REGISTRY = [
          exact("private_key", ["PRIVATE KEY-----"], scan: Scanners.method(:private_key_spans)),
          exact("aws_access_key", %w[AKIA ASIA ABIA ACCA], pattern: AWS_ACCESS_KEY),
          exact("gcp_api_key", ["AIza"], pattern: GCP_API_KEY),
          Detector.new(name: "azure_storage_key", prefilter: ["accountkey="], pattern: AZURE_STORAGE_KEY, group: 1),
          exact("github_token", %w[ghp_ gho_ ghu_ ghs_ ghr_ github_pat_], pattern: GITHUB_TOKEN),
          exact("stripe_key", %w[sk_live_ sk_test_ rk_live_ rk_test_ whsec_], pattern: STRIPE_KEY),
          exact("slack_token", ["xox"], pattern: SLACK_TOKEN),
          exact("slack_webhook", ["hooks.slack.com/services/"], pattern: SLACK_WEBHOOK),
          exact("anthropic_key", ["sk-ant-"], pattern: ANTHROPIC_KEY),
          exact("openai_key", ["sk-"], pattern: OPENAI_KEY),
          exact("jwt", ["eyJ"], scan: Scanners.method(:jwt_spans)),
          exact("fixwire_secret_key", %w[_sk_live_ _sk_test_], pattern: FIXWIRE_SECRET_KEY),
          # The password in scheme://user:password@host (the user stays).
          exact("url_credentials", ["://"], scan: Scanners.method(:url_credential_spans),
                                            validate: Validators.method(:unmasked?)),
          # Bearer and Basic credentials outside a header (messages, breadcrumbs).
          Detector.new(name: "http_auth", prefilter: %w[bearer basic], pattern: HTTP_AUTH, group: 1,
                       validate: Validators.method(:credential?)),
          Detector.new(name: "secret_assignment", prefilter: %w[pass pwd secret key token credential sess sig code],
                       pattern: SECRET_ASSIGNMENT, group: 1, validate: Validators.method(:unmasked?)),
          exact("email", ["@"], scan: Scanners.method(:email_spans)),
          Detector.new(name: "credit_card", scan: Scanners.method(:card_spans)),
          Detector.new(name: "iban", pattern: IBAN, validate: Validators.method(:iban?)),
          exact("us_ssn", ["-"], scan: Scanners.method(:ssn_spans)),
          Detector.new(name: "tr_tckn", scan: Scanners.method(:tckn_spans)),
          exact("phone", ["+"], pattern: PHONE, validate: Validators.method(:phone?)),
          exact(IPV4, ["."], pattern: IPV4_ADDRESS)
        ].freeze

        private_class_method :exact

        # The named detectors, in the order given.
        def self.named(names)
          names.map do |name|
            REGISTRY.find { |d| d.name == name } or raise ArgumentError, "redact: unknown detector #{name.inspect}"
          end
        end
      end
    end
  end
end
