import Foundation

/// Appends one summarized, timestamped entry to today's Obsidian daily note.
/// Each entry includes both a compact summary and a bounded, redacted evidence
/// excerpt from the raw staging log so later recall can answer exact questions
/// without relying solely on model-written paraphrase.
enum DailyNoteWriter {

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Append `- HH:mm — <summary>` to the daily note for `date`'s calendar day.
    /// `dailyNotesDir` is the user-chosen Obsidian folder (see `Settings`).
    @discardableResult
    static func appendSummary(_ summary: String, at date: Date, to dailyNotesDir: String) -> Bool {
        appendEntry(summary: summary, evidence: nil, at: date, to: dailyNotesDir)
    }

    /// Append a summary plus optional redacted source evidence. The evidence is
    /// intentionally stored beside the model summary in Obsidian: the summary is
    /// for fast scanning, while the evidence preserves enough local context for
    /// questions like "what did I tell Mike?" without needing the original app.
    @discardableResult
    static func appendEntry(summary: String,
                            evidence: String?,
                            at date: Date,
                            to dailyNotesDir: String) -> Bool {
        let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        let dateString = fileDateFormatter.string(from: date)
        let fileURL = URL(fileURLWithPath: dailyNotesDir)
            .appendingPathComponent("\(dateString).md")

        ensureDirectory(dailyNotesDir)
        ensureFile(at: fileURL, dateString: dateString)

        var entry = "- \(timeFormatter.string(from: date)) — \(cleaned)\n"
        if let evidence = evidence?.trimmingCharacters(in: .whitespacesAndNewlines),
           !evidence.isEmpty {
            entry += "  - Evidence:\n"
            entry += "    ```text\n"
            for line in evidence.split(separator: "\n", omittingEmptySubsequences: false) {
                entry += "    \(line)\n"
            }
            entry += "    ```\n"
        }
        return append(entry, to: fileURL)
    }

    /// Ensure the daily note for `date` exists (with front-matter), creating it
    /// empty if needed. Used so "Open today's note" always has a file to open.
    static func ensureNoteExists(for date: Date, in dailyNotesDir: String) {
        let dateString = fileDateFormatter.string(from: date)
        let fileURL = URL(fileURLWithPath: dailyNotesDir)
            .appendingPathComponent("\(dateString).md")
        ensureDirectory(dailyNotesDir)
        ensureFile(at: fileURL, dateString: dateString)
    }

    // MARK: - File mechanics

    private static func ensureDirectory(_ dailyNotesDir: String) {
        try? FileManager.default.createDirectory(
            atPath: dailyNotesDir,
            withIntermediateDirectories: true)
    }

    /// Create the file with a front-matter header if it doesn't exist.
    private static func ensureFile(at url: URL, dateString: String) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let header = """
        ---
        date: \(dateString)
        ---

        # \(dateString)

        """
        try? header.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Append via FileHandle → seekToEnd → write.
    @discardableResult
    private static func append(_ text: String, to url: URL) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }
}

/// Converts the transient raw staging log into a small, redacted source excerpt
/// suitable for Obsidian. This deliberately does not summarize: it preserves the
/// words the Accessibility tree exposed, capped and scrubbed, so downstream
/// agents have evidence rather than only the model's interpretation.
enum EvidenceFormatter {
    private static let maxRecordChars = 1_200
    private static let maxTotalChars = 6_000
    private static let maxRecords = 8

    static func format(_ rawText: String) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let records = splitRecords(trimmed)
        var kept: [String] = []
        var total = 0

        for record in records.suffix(maxRecords) {
            let cleaned = cleanRecord(record)
            guard !cleaned.isEmpty else { continue }
            let redacted = SensitiveFilter.redact(cleaned) ?? cleaned
            let capped = cap(redacted, to: maxRecordChars)
            if total + capped.count > maxTotalChars { break }
            kept.append(capped)
            total += capped.count
        }

        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: "\n\n---\n\n")
    }

    private static func splitRecords(_ rawText: String) -> [String] {
        rawText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func cleanRecord(_ record: String) -> String {
        let lines = record
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !lines.isEmpty else { return "" }

        var cleaned: [String] = []
        var previous: String?
        for line in lines {
            let collapsed = line
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !collapsed.isEmpty else { continue }
            guard collapsed != previous else { continue }
            guard !isLowSignalChrome(collapsed) else { continue }
            cleaned.append(collapsed)
            previous = collapsed
        }
        return cleaned.joined(separator: "\n")
    }

    private static func isLowSignalChrome(_ line: String) -> Bool {
        let lower = line.lowercased()
        let chrome = [
            "back", "forward", "reload", "share", "search", "new tab",
            "minimize", "maximize", "close", "toolbar", "sidebar"
        ]
        return line.count < 3 || chrome.contains(lower)
    }

    private static func cap(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n[truncated]"
    }
}
