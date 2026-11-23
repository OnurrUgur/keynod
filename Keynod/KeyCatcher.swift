import Foundation

/// Spots API keys, tokens, and private keys in copied text so they can be
/// saved straight into the Vault or cleared from the clipboard.
/// Rules inspect shape only; nothing leaves the Mac and values are never logged.
enum KeyCatcher {
    /// A secret found in copied text. Prints as its kind only so values can never leak to logs.
    struct Finding: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        /// e.g. "OpenAI API Key"; also the default title of the secret created from it.
        let kind: String
        /// The label of the concealed field in that secret.
        let label: String
        let value: String

        var description: String { kind }
        var debugDescription: String { kind }
    }

    private struct Rule {
        let kind: String
        let label: String
        let regex: NSRegularExpression
        /// Dashed words ("sk-this-is-just-a-long-slug") look like keys; real ones carry digits.
        var needsDigit = false

        init(_ kind: String, _ label: String, _ pattern: String, needsDigit: Bool = false) {
            self.kind = kind
            self.label = label
            regex = try! NSRegularExpression(pattern: pattern)
            self.needsDigit = needsDigit
        }
    }

    /// Most specific first (e.g. `sk-ant-` and `sk-or-v1-` before generic OpenAI `sk-`).
    private static let rules: [Rule] = [
        // AI providers
        Rule("Anthropic API Key", "Key", "(?<![A-Za-z0-9_-])sk-ant-[A-Za-z0-9_-]{20,}"),
        Rule("OpenRouter API Key", "Key", "(?<![A-Za-z0-9_-])sk-or-v1-[A-Za-z0-9]{40,}"),
        Rule("OpenAI API Key", "Key", "(?<![A-Za-z0-9_-])sk-(?!ant-|or-)[A-Za-z0-9_-]{20,}", needsDigit: true),
        Rule("fal.ai API Key", "Key", "(?<![A-Za-z0-9_-])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}:[0-9a-fA-F]{32}(?![A-Za-z0-9_-])"),
        Rule("Groq API Key", "Key", "(?<![A-Za-z0-9_])gsk_[A-Za-z0-9]{20,}"),
        Rule("Perplexity API Key", "Key", "(?<![A-Za-z0-9_-])pplx-[A-Za-z0-9]{30,}"),
        Rule("Replicate API Token", "Token", "(?<![A-Za-z0-9_])r8_[A-Za-z0-9]{20,}"),
        Rule("Hugging Face Token", "Token", "(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{24,}"),
        Rule("ElevenLabs API Key", "Key", "(?<![A-Za-z0-9_])sk_[0-9a-f]{40,}"),

        // Cloud, Dev & SaaS
        Rule("GitHub Token", "Token", "(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,}"),
        Rule("GitHub Token", "Token", "(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36,}"),
        Rule("AWS Access Key", "Access Key ID", "(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])"),
        Rule("Stripe Live Key", "Key", "(?<![A-Za-z0-9_])(?:sk|rk)_live_[A-Za-z0-9]{16,}"),
        Rule("Slack Token", "Token", "(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}"),
        Rule("Google API Key", "Key", "(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}"),
        Rule("Supabase Token", "Token", "(?<![A-Za-z0-9_])sbp_[0-9a-f]{32,}"),
        Rule("Resend API Key", "Key", "(?<![A-Za-z0-9_])re_[A-Za-z0-9_]{20,}"),
        Rule("Linear API Key", "Key", "(?<![A-Za-z0-9_])lin_api_[A-Za-z0-9]{20,}"),
        Rule("DigitalOcean Token", "Token", "(?<![A-Za-z0-9_])dop_v1_[0-9a-f]{64}"),
        Rule("npm Access Token", "Token", "(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{30,}"),
        Rule("PyPI API Token", "Token", "(?<![A-Za-z0-9_-])pypi-[A-Za-z0-9_-]{30,}"),
        Rule("Figma Access Token", "Token", "(?<![A-Za-z0-9_])figd_[A-Za-z0-9_-]{20,}"),
        Rule("Sentry Auth Token", "Token", "(?<![A-Za-z0-9_])sntry[su]_[A-Za-z0-9_=+-]{20,}"),
        Rule("PostHog API Key", "Key", "(?<![A-Za-z0-9_])phx_[A-Za-z0-9]{20,}"),
        Rule("Doppler Token", "Token", "(?<![A-Za-z0-9_.])dp\\.st\\.[A-Za-z0-9._-]{20,}"),
        Rule("Telegram Bot Token", "Token", "(?<![0-9A-Za-z_-])[0-9]{8,10}:AA[A-Za-z0-9_-]{33}(?![A-Za-z0-9_-])"),
        Rule("JSON Web Token", "Token", "(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"),
    ]

    private static let pemBegin = try! NSRegularExpression(pattern: "-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----")
    private static let pemEnd = try! NSRegularExpression(pattern: "-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----")

    /// `text` with every secret the rules recognise replaced by a short marker
    /// such as "‹redacted OpenAI API Key›". A private key goes from its header
    /// to its footer (to the end of the text if the footer is missing). Best
    /// effort: a secret without a known shape is left as it is.
    static func redact(_ text: String) -> String {
        var out = text
        func marker(_ kind: String) -> String { "\u{2039}redacted \(kind)\u{203A}" }

        while let begin = pemBegin.firstMatch(in: out, range: NSRange(location: 0, length: (out as NSString).length)) {
            let ns = out as NSString
            let rest = NSRange(location: begin.range.location, length: ns.length - begin.range.location)
            let upper = pemEnd.firstMatch(in: out, range: rest).map { NSMaxRange($0.range) } ?? ns.length
            out = ns.replacingCharacters(in: NSRange(location: begin.range.location, length: upper - begin.range.location),
                                         with: marker("Private Key"))
        }
        for rule in rules {
            let ns = out as NSString
            let matches = rule.regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let result = NSMutableString(string: ns)
            for match in matches.reversed() {
                if rule.needsDigit && !ns.substring(with: match.range).contains(where: \.isNumber) { continue }
                result.replaceCharacters(in: match.range, with: marker(rule.kind))
            }
            out = result as String
        }
        return out
    }

    /// The first secret found in `text`, or nil.
    static func detect(_ text: String) -> Finding? {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)

        // A private key is saved whole, from its header to its footer.
        if let begin = pemBegin.firstMatch(in: text, range: all) {
            let rest = NSRange(location: begin.range.location, length: ns.length - begin.range.location)
            let upper = pemEnd.firstMatch(in: text, range: rest).map { NSMaxRange($0.range) } ?? ns.length
            let block = ns.substring(with: NSRange(location: begin.range.location, length: upper - begin.range.location))
            return Finding(kind: "Private Key", label: "Private Key", value: block.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for rule in rules {
            for match in rule.regex.matches(in: text, range: all) {
                let token = ns.substring(with: match.range)
                if rule.needsDigit && !token.contains(where: \.isNumber) { continue }
                return Finding(kind: rule.kind, label: rule.label, value: token)
            }
        }
        return nil
    }
}
