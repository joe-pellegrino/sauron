import Foundation

/// Content-based defense against logging secrets. The app blocklist only knows
/// about whole *apps* (1Password, Keychain); it can't catch a credit-card number
/// typed into a browser checkout, an API key in a `.env` open in VS Code, or a
/// bank balance on a web page. This filter runs on every captured string at
/// capture time — BEFORE anything is written to `pending.log` — and masks
/// anything that looks like a card number, SSN, bank/routing number, secret, or
/// token.
///
/// It is deliberately biased toward over-redaction: a few false positives
/// (a redacted order number) are an acceptable price for never staging a real
/// card number. This is a backstop, not a guarantee — see `looksSensitiveHost`
/// and the secure-field skip in `WindowReader` for the other layers.
enum SensitiveFilter {

    // MARK: - Public entry points

    /// Mask sensitive substrings in captured text. Returns nil only if the input
    /// was nil; otherwise returns the (possibly redacted) string.
    static func redact(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return text }
        // Cards first (Luhn-gated, custom) so a joined 16-digit number gets the
        // precise "[redacted-card]" tag before the generic long-digit rule below
        // would otherwise swallow it as "[redacted-number]".
        var out = redactCreditCards(text)
        for rule in rules {
            out = rule.apply(out)
        }
        return out
    }

    /// Hosts whose pages should never have their body text captured at all
    /// (banking, brokerages, health, government). Substring match on the URL host,
    /// case-insensitive. Extend via `Config.sensitiveHostSubstrings`.
    static func looksSensitiveHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return Config.sensitiveHostSubstrings.contains { host.contains($0) }
    }

    // MARK: - Regex rules (straight find-and-replace)

    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
        func apply(_ s: String) -> String {
            let range = NSRange(s.startIndex..., in: s)
            return regex.stringByReplacingMatches(in: s, options: [], range: range,
                                                  withTemplate: replacement)
        }
    }

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // Patterns here are compile-time constants; a failure is a programmer
        // error, so trapping is appropriate.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Order matters: redact structured secrets (PEM, JWT, key-prefixed tokens)
    /// before the broad catch-alls so the specific labels win.
    private static let rules: [Rule] = [
        // PEM private-key blocks.
        Rule(regex: rx("-----BEGIN[^-]*PRIVATE KEY-----[\\s\\S]*?-----END[^-]*PRIVATE KEY-----"),
             replacement: "[redacted-private-key]"),
        // JWTs (header.payload.signature, all base64url).
        Rule(regex: rx("\\beyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}\\b"),
             replacement: "[redacted-jwt]"),
        // AWS access key IDs.
        Rule(regex: rx("\\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[A-Z0-9]{16}\\b"),
             replacement: "[redacted-aws-key]"),
        // GitHub / Slack / OpenAI style prefixed tokens.
        Rule(regex: rx("\\b(?:ghp|gho|ghu|ghs|ghr|github_pat|xox[baprs]|sk|pk|rk)[-_][A-Za-z0-9_-]{16,}\\b"),
             replacement: "[redacted-token]"),
        // label: value  — password / secret / token / key / authorization.
        // The optional `(?:[A-Za-z0-9]+_)*` prefix catches UPPER_SNAKE env-var
        // names like AWS_SECRET / DB_PASSWORD where a plain `\b` before the
        // keyword would fail (no boundary between `_` and the next letter). The
        // trailing `\b` still guards against false hits like "Secretary:" or
        // "author:" (so "authorization" is spelled out, not bare "auth").
        Rule(regex: rx("(?i)\\b((?:[A-Za-z0-9]+_)*(?:password|passwd|pwd|passphrase|secret|api[_-]?key|access[_-]?key|secret[_-]?key|client[_-]?secret|authorization|bearer|token)s?)\\b\\s*[:=]\\s*\\S+"),
             replacement: "$1: [redacted]"),
        // SSN.
        Rule(regex: rx("\\b\\d{3}-\\d{2}-\\d{4}\\b"),
             replacement: "[redacted-ssn]"),
        // IBAN.
        Rule(regex: rx("\\b[A-Z]{2}\\d{2}[A-Z0-9]{11,30}\\b"),
             replacement: "[redacted-iban]"),
        // Bank/routing/account-length bare digit runs (12+ digits) that aren't
        // caught as cards. Backstop for account & routing numbers.
        Rule(regex: rx("\\b\\d{12,}\\b"),
             replacement: "[redacted-number]"),
        // High-entropy tokens: long mixed letter+digit strings (API keys, hashes).
        // Require both a letter and a digit to spare ordinary long words.
        Rule(regex: rx("\\b(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*\\d)[A-Za-z0-9_-]{32,}\\b"),
             replacement: "[redacted-token]"),
    ]

    // MARK: - Credit cards (Luhn-validated)

    /// Find 13–19 digit sequences (allowing spaces/dashes between groups) and
    /// redact those that pass the Luhn checksum — i.e. real card numbers — while
    /// leaving arbitrary long numbers (already handled above) and IDs alone.
    private static let cardCandidate = rx("\\b(?:\\d[ -]?){13,19}\\b")

    private static func redactCreditCards(_ s: String) -> String {
        let ns = s as NSString
        let matches = cardCandidate.matches(in: s, options: [],
                                            range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }

        var result = s
        // Replace from the end so earlier ranges stay valid.
        for match in matches.reversed() {
            let raw = ns.substring(with: match.range)
            let digits = raw.compactMap { $0.wholeNumberValue }
            guard digits.count >= 13, digits.count <= 19, luhnValid(digits) else { continue }
            if let r = Range(match.range, in: result) {
                result.replaceSubrange(r, with: "[redacted-card]")
            }
        }
        return result
    }

    private static func luhnValid(_ digits: [Int]) -> Bool {
        var sum = 0
        var double = false
        for d in digits.reversed() {
            var v = d
            if double { v *= 2; if v > 9 { v -= 9 } }
            sum += v
            double.toggle()
        }
        return sum % 10 == 0
    }
}
