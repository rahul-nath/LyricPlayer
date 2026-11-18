import XCTest
@testable import LyricPlayer

final class TranscriptDomainTests: XCTestCase {
    func testActiveLineLookupHandlesPlaybackAndSeekBoundaries() throws {
        let title = try XCTUnwrap(NormalizedTrackTitle("Meditations - Book 1"))
        let transcript = LyricTranscript.parse(
            contents: """
            [00:10.00]First
            [00:20.00]Second
            [00:30.00]Third
            """,
            title: title
        )

        XCTAssertNil(transcript.activeLineIndex(at: 9.99))
        XCTAssertEqual(transcript.activeLineIndex(at: 10), 0)
        XCTAssertEqual(transcript.activeLineIndex(at: 24), 1)
        XCTAssertEqual(transcript.activeLineIndex(at: 90), 2)
        XCTAssertEqual(transcript.activeLineIndex(at: 12), 0, "A backward seek must resolve directly")
    }

    func testParserSortsLinesAndSkipsMetadataAndMalformedInput() throws {
        let title = try XCTUnwrap(NormalizedTrackTitle("Meditations - Book 2"))
        let transcript = LyricTranscript.parse(
            contents: """
            [ar:Marcus Aurelius]
            malformed
            [00:20.00]Second
            [00:70.00]Invalid seconds
            [00:10.50]First
            """,
            title: title
        )

        XCTAssertEqual(
            transcript.lines,
            [
                LyricLine(timestampSeconds: 10.5, text: "First"),
                LyricLine(timestampSeconds: 20, text: "Second")
            ]
        )
    }

    func testParserAcceptsWhisperHeaderAndLeadingSpace() throws {
        let title = try XCTUnwrap(NormalizedTrackTitle("Meditations - Book 10"))
        let transcript = LyricTranscript.parse(
            contents: """
            [by:whisper.cpp]
            [00:00.00] The real corpus includes a leading space.
            [00:04.25] It is trimmed without changing the text.
            """,
            title: title
        )

        XCTAssertEqual(
            transcript.lines,
            [
                LyricLine(timestampSeconds: 0, text: "The real corpus includes a leading space."),
                LyricLine(timestampSeconds: 4.25, text: "It is trimmed without changing the text.")
            ]
        )
    }

    func testTitleNormalizationIsExactAfterDefinedTransformations() throws {
        XCTAssertEqual(
            NormalizedTrackTitle("  MEDITATIONS   - Book 1!  "),
            NormalizedTrackTitle("meditations book 1")
        )
        XCTAssertNotEqual(
            NormalizedTrackTitle("meditations - book 1"),
            NormalizedTrackTitle("meditations - book 11")
        )
        XCTAssertNotEqual(
            NormalizedTrackTitle("meditations - book 1"),
            NormalizedTrackTitle("meditations - book 12")
        )
    }

    func testCatalogBindsBookOneOnlyToBookOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "[00:00.00]Eleven".write(
            to: directory.appendingPathComponent("meditations - book 11.lrc"),
            atomically: true,
            encoding: .utf8
        )
        try "[00:00.00]Twelve".write(
            to: directory.appendingPathComponent("meditations - book 12.lrc"),
            atomically: true,
            encoding: .utf8
        )
        try "[00:00.00]One".write(
            to: directory.appendingPathComponent("meditations - book 1.lrc"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = TranscriptCatalog(resourceDirectories: [directory])
        guard case let .matched(transcript) = catalog.resolve(trackTitle: "meditations - book 1") else {
            return XCTFail("Book 1 must not bind to Book 11 or Book 12")
        }
        XCTAssertEqual(transcript.title, NormalizedTrackTitle("meditations - book 1"))
        XCTAssertEqual(transcript.lines.map(\.text), ["One"])
    }

    func testDuplicateNormalizedTitlesFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "[00:00.00]First".write(
            to: directory.appendingPathComponent("meditations - book 1.lrc"),
            atomically: true,
            encoding: .utf8
        )
        try "[00:00.00]Collision".write(
            to: directory.appendingPathComponent("MEDITATIONS BOOK 1!.lrc"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = TranscriptCatalog(resourceDirectories: [directory])
        guard case .ambiguous = catalog.resolve(trackTitle: "meditations - book 1") else {
            return XCTFail("Ambiguous normalized titles must fail closed")
        }
    }

    func testMissingTitleFailsClosed() {
        let catalog = TranscriptCatalog(resourceDirectories: [])

        guard case let .missing(title) = catalog.resolve(trackTitle: "meditations - book 3") else {
            return XCTFail("A missing transcript must not bind to another title")
        }
        XCTAssertEqual(title, NormalizedTrackTitle("meditations - book 3"))
    }

    func testHigherPrecedenceDirectoryOverridesBundledTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleDirectory = root.appendingPathComponent("Bundle", isDirectory: true)
        let documentsDirectory = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let filename = "meditations - book 4.lrc"
        try "[00:00.00]Bundled".write(
            to: bundleDirectory.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
        try "[00:00.00]Documents".write(
            to: documentsDirectory.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )

        let catalog = TranscriptCatalog(resourceDirectories: [bundleDirectory, documentsDirectory])
        guard case let .matched(transcript) = catalog.resolve(trackTitle: "meditations - book 4") else {
            return XCTFail("Documents should override the bundled transcript")
        }
        XCTAssertEqual(transcript.lines.map(\.text), ["Documents"])
    }
}
