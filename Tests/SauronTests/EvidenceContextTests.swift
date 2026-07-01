import XCTest
@testable import Sauron

final class EvidenceContextTests: XCTestCase {
    func testEvidenceFormatterPreservesMessageLikeContext() {
        let raw = """
        [14:39] Slack — Michael Muscatelli
        Joe: Can you check the K. Pacho event page copy before we send it?
        Michael: Yes, I will review the content-creation task.

        [14:42] Slack — Michael Muscatelli
        Joe: The mitzvah and wedding sections need to be clearer.
        """

        let evidence = EvidenceFormatter.format(raw) ?? ""

        XCTAssertTrue(evidence.contains("Slack — Michael Muscatelli"))
        XCTAssertTrue(evidence.contains("Joe: Can you check the K. Pacho event page copy"))
        XCTAssertTrue(evidence.contains("mitzvah and wedding sections"))
    }

    func testEvidenceFormatterCapsTotalSizeForLargeChunks() {
        // A large multi-record chunk (the kind that previously dumped ~6 KB per
        // flush and bloated daily notes past Obsidian's index limit) must now be
        // capped to a short anchor. Build 20 fat records of distinct filler.
        let raw = (0..<20).map { i in
            "[10:\(String(format: "%02d", i))] Editor — File\(i).swift\n"
                + String(repeating: "line \(i) of content here ", count: 60)
        }.joined(separator: "\n\n")

        let evidence = EvidenceFormatter.format(raw) ?? ""

        // Tight bound: a few capped records plus separators, never kilobytes.
        XCTAssertLessThanOrEqual(evidence.count, 1_000)
        XCTAssertFalse(evidence.isEmpty)
    }

    func testEvidenceFormatterRedactsSensitiveValues() {
        let password = "PLACEHOLDER" + "pwvalue00"
        let raw = """
        [09:00] Safari — Signup Form
        Joe: password: \(password)
        Continue
        """

        let evidence = EvidenceFormatter.format(raw) ?? ""

        XCTAssertFalse(evidence.contains(password))
        XCTAssertTrue(evidence.lowercased().contains("redacted"))
    }

    func testDailyNoteWriterStoresSummaryAndEvidenceTogether() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sauron-evidence-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let date = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01-ish local
        let wrote = DailyNoteWriter.appendEntry(
            summary: "Coordinated with Michael about K. Pacho content.",
            evidence: "[14:39] Slack — Michael\nJoe: Can you check the K. Pacho event page?",
            at: date,
            to: dir.path
        )

        XCTAssertTrue(wrote)
        let files = try FileManager.default.contentsOfDirectory(at: dir,
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(text.contains("Coordinated with Michael about K. Pacho content."))
        XCTAssertTrue(text.contains("Evidence:"))
        XCTAssertTrue(text.contains("Joe: Can you check the K. Pacho event page?"))
    }
}
