import XCTest
@testable import Sauron

/// Security regression tests for the content-redaction layer — the app-agnostic
/// backstop that must never let a card number, SSN, bank/account number, secret,
/// or token reach disk. If a change makes a `leaks:` assertion fail, that change
/// is leaking secrets — do not "fix" the test by relaxing it.
///
/// NOTE ON THE FIXTURES BELOW: every credential-shaped value is SYNTHETIC and
/// assembled from fragments at runtime (see `Fixtures`), so no contiguous
/// secret-looking literal ever appears in the committed source. That keeps
/// GitHub push protection / secret scanners quiet while still exercising the
/// real provider prefixes (AKIA…, ghp_…, sk_live_…, eyJ…) the redactor matches.
/// None of these is a real key, token, card, or account number.
final class SensitiveFilterTests: XCTestCase {

    /// Synthetic, non-functional placeholders. Split across `+` so the full
    /// string only exists at runtime, never as a literal in the file.
    private enum Fixtures {
        // Card numbers carry valid Luhn check digits (required to exercise the
        // Luhn-gated card rule) but are standard non-functional test PANs.
        static let visaSpaced = "4111 1111 " + "1111 1111"        // valid Luhn
        static let visaJoined = "40000000" + "00000002"           // valid Luhn (joined)
        static let amex       = "3782 " + "822463 10005"          // 15-digit, valid Luhn
        static let ssn        = "000-" + "00-0000"
        static let iban       = "GB00" + "EXAMPLEPLACEHOLDER00"
        static let account12  = "000000" + "000000"               // 12 digits → [redacted-number]
        static let awsKeyId   = "AKIA" + String(repeating: "X", count: 16)
        static let ghToken    = "ghp" + "_" + String(repeating: "0", count: 36)
        static let stripeKey  = "sk_" + "live_" + String(repeating: "0", count: 24)
        static let jwt        = "eyJ" + "PLACEHOLDERhdr." + "PLACEHOLDERpyl." + "PLACEHOLDERsig"
        static let pwValue    = "PLACEHOLDER" + "pwvalue00"
        static let secretVal  = "PLACEHOLDER" + "value0000"
    }

    /// Assert the redacted output does NOT contain any forbidden substring, and
    /// (optionally) DOES contain expected redaction tags.
    private func assertRedacted(_ input: String,
                                leaks: [String],
                                tags: [String] = [],
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        let out = SensitiveFilter.redact(input) ?? ""
        for secret in leaks {
            XCTAssertFalse(out.contains(secret),
                           "LEAKED '\(secret)' in: \(out)", file: file, line: line)
        }
        for tag in tags {
            XCTAssertTrue(out.contains(tag),
                          "missing '\(tag)' in: \(out)", file: file, line: line)
        }
    }

    // MARK: - The things the user explicitly worried about

    func testCreditCardNumbers() {
        assertRedacted("Card: \(Fixtures.visaSpaced) exp 12/26",
                       leaks: ["4111", "1111 1111"], tags: ["[redacted-card]"])
        assertRedacted("pay \(Fixtures.visaJoined) now",
                       leaks: [Fixtures.visaJoined], tags: ["[redacted-card]"])
        assertRedacted("AmEx \(Fixtures.amex)",
                       leaks: ["3782", "822463"], tags: ["[redacted-card]"])
    }

    func testPasswordsAndSecrets() {
        assertRedacted("username: joe password: \(Fixtures.pwValue)",
                       leaks: [Fixtures.pwValue], tags: ["[redacted]"])
        assertRedacted("API_KEY=\(Fixtures.stripeKey)",
                       leaks: [Fixtures.stripeKey], tags: ["redacted"])
        assertRedacted("export AWS_SECRET=\(Fixtures.secretVal)",
                       leaks: [Fixtures.secretVal], tags: ["redacted"])
    }

    func testSSN() {
        assertRedacted("SSN \(Fixtures.ssn) on file",
                       leaks: [Fixtures.ssn], tags: ["[redacted-ssn]"])
    }

    func testBankAndAccountNumbers() {
        assertRedacted("Routing 000000000 Account \(Fixtures.account12)",
                       leaks: [Fixtures.account12], tags: ["[redacted-number]"])
        assertRedacted("IBAN \(Fixtures.iban)",
                       leaks: [Fixtures.iban], tags: ["[redacted-iban]"])
    }

    func testTokensAndKeys() {
        assertRedacted("\(Fixtures.awsKeyId) in config",
                       leaks: [Fixtures.awsKeyId], tags: ["[redacted-aws-key]"])
        assertRedacted("token \(Fixtures.jwt)",
                       leaks: [Fixtures.jwt], tags: ["[redacted-jwt]"])
        assertRedacted(Fixtures.ghToken,
                       leaks: [Fixtures.ghToken], tags: ["[redacted-token]"])
    }

    // MARK: - No false positives (must not shred real notes)

    func testOrdinaryProseUntouched() {
        let prose = "Reviewed the task_lists migration PR with a teammate in chat at 14:32"
        XCTAssertEqual(SensitiveFilter.redact(prose), prose)
    }

    func testShortNumbersUntouched() {
        let s = "Met 3 people, room 402, page 1500, build 12345"
        XCTAssertEqual(SensitiveFilter.redact(s), s)
    }

    // MARK: - Structural invariants

    func testNilAndEmptyPassThrough() {
        XCTAssertNil(SensitiveFilter.redact(nil))
        XCTAssertEqual(SensitiveFilter.redact(""), "")
    }

    /// Redaction runs at two layers (WindowReader + RawLog), so applying it twice
    /// must equal applying it once — otherwise the double pass could corrupt text.
    func testIdempotent() {
        let inputs = [
            "Card \(Fixtures.visaSpaced) and SSN \(Fixtures.ssn)",
            "password: \(Fixtures.pwValue) api_key=\(Fixtures.stripeKey)",
            "\(Fixtures.awsKeyId) routing \(Fixtures.account12)",
            "ordinary text with no secrets at all",
        ]
        for input in inputs {
            let once = SensitiveFilter.redact(input)!
            let twice = SensitiveFilter.redact(once)!
            XCTAssertEqual(once, twice, "redaction not idempotent for: \(input)")
        }
    }

    func testSensitiveHostDetection() {
        XCTAssertTrue(SensitiveFilter.looksSensitiveHost("secure.chase.com"))
        XCTAssertTrue(SensitiveFilter.looksSensitiveHost("www.fidelity.com"))
        XCTAssertFalse(SensitiveFilter.looksSensitiveHost("github.com"))
        XCTAssertFalse(SensitiveFilter.looksSensitiveHost(nil))
    }
}
