import XCTest

/// Fixtures are fake, and assembled from pieces at run time so no literal in
/// this file looks like a live credential to a secret scanner.
private func key(_ parts: String...) -> String { parts.joined() }

final class KeyCatcherTests: XCTestCase {
    private let pem = [
        key("-----BEGIN ", "PRIVATE KEY-----"),
        "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgFakeKeyBytes",
        key("-----END ", "PRIVATE KEY-----"),
    ].joined(separator: "\n")

    private var aiSamples: [(String, String)] {
        [
            (key("sk-", "ant-", "api03-1234567890abcdefghij1234567890"), "Anthropic API Key"),
            (key("sk-", "or-v1-", "0123456789abcdef0123456789abcdef0123456789abcdef"), "OpenRouter API Key"),
            (key("sk-", "proj-", "1234567890abcdef1234567890"), "OpenAI API Key"),
            (key("12345678-1234-4abc-9def-0123456789ab", ":", "0123456789abcdef0123456789abcdef"), "fal.ai API Key"),
            (key("gsk", "_", "1234567890abcdefghijklmnop"), "Groq API Key"),
            (key("pplx", "-", "1234567890abcdefghijklmnopqrstuvwxyz"), "Perplexity API Key"),
            (key("r8", "_", "1234567890abcdefghijklmnop"), "Replicate API Token"),
            (key("hf", "_", "abcdefghijklmnopqrstuvwxyz123456"), "Hugging Face Token"),
            (key("sk", "_", "0123456789abcdef0123456789abcdef0123456789ab"), "ElevenLabs API Key"),
        ]
    }

    private var cloudSamples: [(String, String)] {
        [
            (key("ghp", "_", "1234567890abcdefghijklmnopqrstuvwxyz"), "GitHub Token"),
            (key("github", "_pat_", "1234567890abcdefghijklmnop"), "GitHub Token"),
            (key("AKIA", "IOSFODNN7EXAMPLE"), "AWS Access Key"),
            (key("sk", "_live_", "1234567890abcdef1234"), "Stripe Live Key"),
            (key("xoxb", "-", "1234567890-abcdefghij"), "Slack Token"),
            (key("AIza", "SyA1234567890abcdefghij1234567890ab"), "Google API Key"),
            (key("sbp", "_", "0123456789abcdef0123456789abcdef01234567"), "Supabase Token"),
            (key("re", "_", "1234567890abcdefghijklmnop"), "Resend API Key"),
            (key("lin", "_api_", "1234567890abcdefghijklmnop"), "Linear API Key"),
            (key("npm", "_", "1234567890abcdefghijklmnopqrstuvwxyz"), "npm Access Token"),
            (key("pypi", "-", "1234567890abcdefghijklmnopqrstuvwxyz"), "PyPI API Token"),
            (key("figd", "_", "1234567890abcdefghijklmnop"), "Figma Access Token"),
            (key("sntrys", "_", "1234567890abcdefghijklmnop"), "Sentry Auth Token"),
            (key("phx", "_", "1234567890abcdefghijklmnop"), "PostHog API Key"),
            (key("dp.st.", "prd.", "1234567890abcdefghijklmnop"), "Doppler Token"),
            (key("123456789", ":AA", "HdqTcvCH1vGWJxfSeofSAs0K5PALDsaw1"), "Telegram Bot Token"),
            (key("eyJhbGciOiJIUzI1NiJ9", ".", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", ".", "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"),
             "JSON Web Token"),
        ]
    }

    func testDetectsModernAIKeys() {
        for (token, expectedKind) in aiSamples {
            let finding = KeyCatcher.detect("export KEY=\(token)")
            XCTAssertEqual(finding?.kind, expectedKind, expectedKind)
            XCTAssertEqual(finding?.value, token, expectedKind)
            XCTAssertEqual(finding?.description, expectedKind, "description must never print secret value")
        }
    }

    func testDetectsCloudAndDevTokens() {
        for (token, expectedKind) in cloudSamples {
            let finding = KeyCatcher.detect(token)
            XCTAssertEqual(finding?.kind, expectedKind, expectedKind)
            XCTAssertEqual(finding?.value, token, expectedKind)
        }
    }

    func testDetectsPEMPrivateKey() {
        let finding = KeyCatcher.detect("prefix\n\(pem)\nsuffix")
        XCTAssertEqual(finding?.kind, "Private Key")
        XCTAssertEqual(finding?.value, pem)
    }

    func testIgnoresPlainSlugsAndOrdinaryText() {
        XCTAssertNil(KeyCatcher.detect("sk-this-is-just-a-very-long-dashed-slug"))
        XCTAssertNil(KeyCatcher.detect("hello world 12345"))
        XCTAssertNil(KeyCatcher.detect("https://fal.ai/models/flux"))
    }

    // MARK: Redaction

    func testRedactsEveryKnownShapeAndKeepsTheRest() {
        for (token, kind) in aiSamples + cloudSamples {
            let text = "curl -H \"Authorization: Bearer \(token)\" https://api.example.com/v1"
            let redacted = KeyCatcher.redact(text)
            XCTAssertFalse(redacted.contains(token), kind)
            XCTAssertTrue(redacted.contains("\u{2039}redacted \(kind)\u{203A}"), "\(kind): \(redacted.count) chars")
            XCTAssertTrue(redacted.hasPrefix("curl -H \"Authorization: Bearer "), kind)
            XCTAssertTrue(redacted.hasSuffix("\" https://api.example.com/v1"), kind)
        }
    }

    func testRedactsSeveralSecretsInOneText() {
        let openAI = key("sk-", "proj-", "1234567890abcdef1234567890")
        let github = key("ghp", "_", "1234567890abcdefghijklmnopqrstuvwxyz")
        let text = "OPENAI_API_KEY=\(openAI) GH=\(github) OPENAI_API_KEY=\(openAI) done"
        let redacted = KeyCatcher.redact(text)
        XCTAssertEqual(redacted, "OPENAI_API_KEY=\u{2039}redacted OpenAI API Key\u{203A} GH=\u{2039}redacted GitHub Token\u{203A} "
            + "OPENAI_API_KEY=\u{2039}redacted OpenAI API Key\u{203A} done")
    }

    func testRedactsPrivateKeyBlocksWholeEvenWithoutFooter() {
        XCTAssertEqual(KeyCatcher.redact("before\n\(pem)\nafter"), "before\n\u{2039}redacted Private Key\u{203A}\nafter")
        let cut = pem.components(separatedBy: "\n").dropLast().joined(separator: "\n")
        XCTAssertEqual(KeyCatcher.redact("cat <<EOF\n\(cut)"), "cat <<EOF\n\u{2039}redacted Private Key\u{203A}")
        let two = "\(pem)\nand\n\(pem)"
        XCTAssertEqual(KeyCatcher.redact(two), "\u{2039}redacted Private Key\u{203A}\nand\n\u{2039}redacted Private Key\u{203A}")
    }

    func testRedactLeavesOrdinaryTextAlone() {
        for text in ["", "git push origin main", "sk-this-is-just-a-very-long-dashed-slug",
                     "https://fal.ai/models/flux", "Done. All tests pass \u{1F389}"] {
            XCTAssertEqual(KeyCatcher.redact(text), text)
        }
    }
}
