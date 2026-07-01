import Foundation
import FoundationModels
import os

/// Summarizes a chunk of the raw staging log into a single concise line using
/// Apple's on-device foundation model (no network — fully local, in keeping
/// with Sauron's zero-network requirement).
///
/// If the model is unavailable (Apple Intelligence off, model not downloaded,
/// unsupported hardware) OR a request throws (e.g. the on-device content-safety
/// model fails to load — `ModelManagerError 1013`, common when disk is full or
/// Apple Intelligence assets are still provisioning), `summarize` returns nil
/// and the caller falls back to a deterministic, non-LLM bullet. The real reason
/// is logged via `os.Logger` (subsystem `com.sauron.Sauron`, category
/// `Summarizer`) so it's diagnosable in Console.app — `log show --predicate
/// 'subsystem == "com.sauron.Sauron"'` — instead of silently swallowed.
enum Summarizer {

    private static let log = Logger(subsystem: "com.sauron.Sauron", category: "Summarizer")

    /// The on-device model has a small (~4k-token) context window shared by the
    /// instructions, input, and output. We condense each chunk to this many
    /// characters of input before sending so a large flush can't overflow it.
    private static let maxModelInputChars = 6_000
    /// Per-record body kept when condensing for the model — enough to convey
    /// what each context was about while keeping breadth across all records.
    private static let maxBodyPerRecordForModel = 200

    private static let instructions = """
    You summarize a chronological activity log of one person's computer use. \
    The log is a series of records: a header line "[HH:mm] App — context" \
    followed by visible text captured from that window.

    Write ONE detailed past-tense summary of what the person was doing across \
    the whole chunk. This summary is the primary record — be specific enough \
    that someone could later answer recall questions from it alone ("what did I \
    tell Mike?", "which file was I editing?", "what did we decide?"). Name the \
    concrete specifics: people involved and what was said or asked of them, the \
    files/projects/PRs/documents touched, topics discussed, decisions reached, \
    and any non-sensitive numbers or identifiers. Prefer naming the actual thing \
    over a vague category — "reviewed the task_lists migration PR" not "worked on \
    tasks". Group related activity and ignore chrome, menus, and boilerplate. No \
    preamble, no bullet points, no markdown, no trailing period-only filler. \
    Four to six sentences, written as a flowing single paragraph suitable for one \
    daily-note bullet read by another agent.

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

        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            log.error("on-device model unavailable: \(String(describing: availability), privacy: .public)")
            return nil
        }

        let input = condenseForModel(trimmed)
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: input)
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? nil : collapseWhitespace(summary)
        } catch {
            // Surface the real failure (often the content-safety model failing to
            // load) instead of silently dropping to the fallback bullet.
            log.error("on-device summarize threw, using fallback: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Condense a raw chunk to fit the on-device model's small context window:
    /// keep every record's header (so the model sees the full breadth of apps and
    /// contexts touched) but trim each body, then keep the most recent records
    /// that fit `maxModelInputChars`. Breadth matters more than depth here — the
    /// summary should name what was done across the whole window.
    private static func condenseForModel(_ rawText: String) -> String {
        let records = rawText.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var condensed: [String] = []
        for record in records {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let header = lines.first else { continue }
            let body = collapseWhitespace(lines.dropFirst().joined(separator: " "))
            let trimmedBody = body.count > maxBodyPerRecordForModel
                ? String(body.prefix(maxBodyPerRecordForModel)) + "…"
                : body
            condensed.append(trimmedBody.isEmpty ? header : "\(header)\n\(trimmedBody)")
        }

        // Keep the most recent records that fit the input budget.
        var kept: [String] = []
        var total = 0
        for record in condensed.reversed() {
            if total + record.count > maxModelInputChars { break }
            kept.append(record)
            total += record.count
        }
        return kept.reversed().joined(separator: "\n\n")
    }

    /// Deterministic fallback when the model can't run. Rather than a bare list
    /// of app names (which says nothing about *what* you were doing), this keeps
    /// each distinct header context — `App — window title · host` — so the note
    /// still records the concrete breadcrumbs: which site, which Slack channel,
    /// which document, which inbox. Deduped, cleaned, and capped so it stays one
    /// readable line.
    static func fallback(_ rawText: String) -> String {
        var contexts: [String] = []
        var seen = Set<String>()
        for line in rawText.split(separator: "\n") {
            // Header lines look like "[HH:mm] App — title · host".
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let after = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard !after.isEmpty else { continue }

            var ctx = collapseWhitespace(String(after))
            if ctx.count > 80 {
                ctx = String(ctx.prefix(80)).trimmingCharacters(in: .whitespaces) + "…"
            }
            let key = ctx.lowercased()
            guard seen.insert(key).inserted else { continue }
            contexts.append(ctx)
            if contexts.count >= 12 { break }
        }

        guard !contexts.isEmpty else {
            return "Activity logged (on-device summary unavailable)."
        }
        return "On-device summary unavailable; visited: \(contexts.joined(separator: "; "))."
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
