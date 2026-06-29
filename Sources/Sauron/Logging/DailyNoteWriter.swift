import Foundation

/// Appends one summarized, timestamped bullet to today's Obsidian daily note.
/// The detailed text lives in the local staging log (`RawLog`); Obsidian only
/// ever sees the rolled-up summary, which keeps the note easy for an agent to
/// read. Handles directory/file creation and front-matter.
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
    static func appendSummary(_ summary: String, at date: Date, to dailyNotesDir: String) {
        let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let dateString = fileDateFormatter.string(from: date)
        let fileURL = URL(fileURLWithPath: dailyNotesDir)
            .appendingPathComponent("\(dateString).md")

        ensureDirectory(dailyNotesDir)
        ensureFile(at: fileURL, dateString: dateString)

        let bullet = "- \(timeFormatter.string(from: date)) — \(cleaned)\n"
        append(bullet, to: fileURL)
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
    private static func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
