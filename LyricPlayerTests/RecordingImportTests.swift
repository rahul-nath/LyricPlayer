import AVFoundation
import XCTest
@testable import LyricPlayer

final class RecordingImportTests: XCTestCase {
    func testEnglishAndSpanishFilesBecomeSeekableSavedRecordings() async throws {
        let testBundle = Bundle(for: Self.self)
        let model = try XCTUnwrap(Bundle.main.url(forResource: "ggml-base", withExtension: "bin"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (language, ext, first, second) in [(SpokenLanguage.english, "m4a", "bicycle", "bridge"),
                                               (.spanish, "wav", "bicicleta", "puente")] {
            guard let fixture = testBundle.url(forResource: language.rawValue, withExtension: ext, subdirectory: "TestAudio") else {
                throw XCTSkip("Generate local speech fixtures with scripts/test_audio.sh first.")
            }
            let saved = try await RecordingImport.run(file: fixture, model: model, language: language, library: root) { _ in }
            XCTAssertTrue(try Recording.list(in: root).contains(saved))
            let text = try String(contentsOf: saved.transcript, encoding: .utf8)
            let transcript = LyricTranscript.parse(contents: text, title: try XCTUnwrap(NormalizedTrackTitle(saved.title)))
            let words = transcript.lines.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(words.contains(first), words)
            XCTAssertTrue(words.contains(second), words)
            XCTAssertGreaterThanOrEqual(transcript.lines.count, 2, text)
            let player = try AVAudioPlayer(contentsOf: XCTUnwrap(saved.audio))
            let last = try XCTUnwrap(transcript.lines.last)
            XCTAssertGreaterThan(last.timestampSeconds, 0)
            XCTAssertLessThan(last.timestampSeconds, player.duration)
            player.currentTime = last.timestampSeconds + 0.01
            XCTAssertEqual(transcript.activeLineIndex(at: player.currentTime), transcript.lines.count - 1)
            player.currentTime = 0
            XCTAssertNotEqual(transcript.activeLineIndex(at: player.currentTime), transcript.lines.count - 1)
        }
    }

    func testBrokenAudioLeavesNoPublishedRecording() async throws {
        let fm = FileManager.default, tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let broken = tmp.appendingPathComponent("broken.wav")
        try Data("broken".utf8).write(to: broken)
        let library = tmp.appendingPathComponent("library")
        do {
            _ = try await RecordingImport.run(file: broken, model: broken, language: .english, library: library) { _ in }
            XCTFail("Malformed audio should fail")
        } catch {
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: library.path), [])
        }
    }
}
