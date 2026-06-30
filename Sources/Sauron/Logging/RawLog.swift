import Foundation

/// Durable, file-backed staging log. Captures are appended here verbatim
/// *first* (so they survive a crash before a summary is written), then drained
/// and summarized into a single Obsidian bullet. Once a chunk is summarized the
/// raw lines are discarded — this file is a transient buffer, not an archive.
///
/// Lives at `~/Library/Application Support/Sauron/pending.log`, on-device only.
@MainActor
final class RawLog {
    private let fileURL: URL
    private var lastKey: String?
    private(set) var lineCount = 0
    /// Timestamp of the first capture in the current pending chunk — used to
    /// datestamp the summary bullet at the start of the window it covers.
    private(set) var firstTimestamp: Date?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Sauron", isDirectory: true)
        // Owner-only directory (0700): the staging buffer can briefly hold
        // pre-summary text, so keep other users/processes out.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        fileURL = dir.appendingPathComponent("pending.log")
        // Recover any chunk left over from a previous run (crash before flush).
        recoverExisting()
    }

    var isEmpty: Bool { lineCount == 0 }

    /// Append a capture, skipping it if its context key matches the previous
    /// one. Returns true if it was written.
    @discardableResult
    func append(_ capture: Capture) -> Bool {
        if capture.key == lastKey { return false }
        lastKey = capture.key
        if firstTimestamp == nil { firstTimestamp = capture.timestamp }

        let record = format(capture)
        write(record)
        lineCount += record.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
        return true
    }

    /// The full pending text, for handing to the summarizer.
    func readAll() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// Discard the pending chunk and reset state after it has been handed off
    /// for writing to Obsidian.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        lineCount = 0
        lastKey = nil
        firstTimestamp = nil
    }

    /// Restore a drained snapshot if the daily-note write fails. Captures that
    /// arrived while the async summary was in flight remain in `pending.log`; the
    /// failed snapshot is prepended so it can be retried on the next flush.
    func restore(_ snapshot: String, firstTimestamp timestamp: Date) {
        let current = readAll()
        let restored: String
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            restored = snapshot
        } else {
            restored = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n"
                + current
        }

        guard let data = restored.data(using: .utf8) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        lineCount = restored.reduce(into: 0) { count, ch in if ch == "\n" { count += 1 } }
        lastKey = nil
        firstTimestamp = timestamp
    }

    // MARK: - Internals

    /// One readable record per capture: a header line plus the captured body.
    ///
    /// This is the single chokepoint where capture data becomes bytes on disk, so
    /// the WHOLE record is passed through `SensitiveFilter.redact` one last time
    /// here — redundant with the redaction `WindowReader` already applied, and
    /// deliberately so. It guarantees the on-disk invariant ("nothing that looks
    /// like a card/SSN/secret/token is ever persisted") structurally, even if a
    /// future code path constructs a `Capture` without going through the reader.
    /// Redaction is idempotent, so the double pass is safe.
    private func format(_ capture: Capture) -> String {
        var header = "[\(Self.timeFormatter.string(from: capture.timestamp))] \(capture.app)"
        if let title = capture.title, !title.isEmpty { header += " — \(title)" }
        if let url = capture.url, let host = URL(string: url)?.host { header += " · \(host)" }

        var record = header + "\n"
        if Config.captureBodyText, let body = capture.body, !body.isEmpty {
            record += body + "\n"
        }
        record += "\n"
        return SensitiveFilter.redact(record) ?? record
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // First write creates the file owner-only (0600).
            FileManager.default.createFile(
                atPath: fileURL.path, contents: data,
                attributes: [.posixPermissions: 0o600])
        }
        // Belt-and-suspenders: re-assert 0600 in case the file pre-existed with
        // looser permissions (e.g. created by an older build).
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// On launch, account for a pending chunk left behind by a crash so its
    /// line count counts toward the next flush.
    private func recoverExisting() {
        let existing = readAll()
        guard !existing.isEmpty else { return }
        lineCount = existing.reduce(into: 0) { count, ch in if ch == "\n" { count += 1 } }
        firstTimestamp = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.creationDate]) as? Date
    }
}
