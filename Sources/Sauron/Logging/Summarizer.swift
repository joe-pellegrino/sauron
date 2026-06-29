import Foundation
import FoundationModels

/// Summarizes a chunk of the raw staging log into a single concise line using
/// Apple's on-device foundation model (no network — fully local, in keeping
/// with Sauron's zero-network requirement).
///
/// If the model is unavailable (Apple Intelligence off, model not downloaded,
/// unsupported hardware), `summarize` returns nil and the caller falls back to
/// a deterministic, non-LLM bullet so the daily note still gets a line.
enum Summarizer {

    private static let instructions = """
    You summarize a chronological activity log of one person's computer use. \
    The log is a series of records: a header line "[HH:mm] App — context" \
    followed by visible text captured from that window.

    Write ONE compact past-tense summary of what the person was doing across \
    the whole chunk. Lead with concrete specifics — projects, files, people, \
    topics, decisions — not vague phrases like "worked on tasks". Group related \
    activity; ignore chrome, menus, and boilerplate. No preamble, no bullet \
    points, no markdown, no trailing period-only filler. Two or three sentences \
    maximum, suitable for a single daily-note bullet read by another agent.

    CRITICAL — never reproduce sensitive information in the summary. The log may \
    contain private data, including things a simple filter cannot catch: \
    passwords, passphrases, PINs, door/lock/safe codes, API keys, tokens, \
    secrets, credit-card or bank-account or routing numbers, SSNs or other \
    government IDs, security-question answers (mother's maiden name, first pet, \
    etc.), salary or account balances, medical details, and home-security or \
    travel/whereabouts details that could aid theft. Summarize only the ACTIVITY \
    ("entered payment details", "reviewed a bank statement", "filled out a \
    signup form") — never the sensitive VALUES themselves. If a record is mostly \
    sensitive data, describe the task at a high level and omit the specifics. \
    Tokens like "[redacted-card]" or "[redacted]" are already-masked secrets: \
    treat them as redacted and never guess or restate what they replaced.
    """

    /// Returns a concise summary, or nil if the on-device model is unavailable
    /// or fails.
    static func summarize(_ rawText: String) async -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: trimmed)
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? nil : collapseWhitespace(summary)
        } catch {
            return nil
        }
    }

    /// Deterministic fallback when the model can't run: list the distinct apps
    /// touched so the note still records *something* for the window.
    static func fallback(_ rawText: String) -> String {
        var apps: [String] = []
        var seen = Set<String>()
        for line in rawText.split(separator: "\n") {
            // Header lines look like "[HH:mm] App — context".
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            var rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if let dash = rest.range(of: " — ") { rest = String(rest[..<dash.lowerBound]) }
            let app = rest.trimmingCharacters(in: .whitespaces)
            if !app.isEmpty, seen.insert(app).inserted { apps.append(app) }
        }
        let appList = apps.isEmpty ? "various apps" : apps.joined(separator: ", ")
        return "Activity across \(appList) (on-device summary unavailable)."
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
