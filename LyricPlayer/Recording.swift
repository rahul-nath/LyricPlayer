import AVFoundation
import Foundation
import whisper

enum SpokenLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    var id: Self { self }
    var label: String { self == .english ? "English" : "Español" }
}

struct Recording: Identifiable, Hashable {
    let directory: URL
    init(directory: URL) {
        self.directory = URL(fileURLWithPath: directory.standardizedFileURL.path, isDirectory: true)
    }

    var id: URL { directory }
    var title: String { directory.lastPathComponent }
    var transcript: URL { directory.appendingPathComponent("transcript.lrc") }
    var audio: URL? {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first { $0.deletingPathExtension().lastPathComponent == "audio" }
    }

    static func list(in library: URL) throws -> [Recording] {
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil,
                                                           options: .skipsHiddenFiles)
            .map { Recording(directory: $0) }
            .filter { $0.audio != nil && FileManager.default.fileExists(atPath: $0.transcript.path) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

enum RecordingError: LocalizedError {
    case audio, model, recognition, empty
    var errorDescription: String? {
        switch self {
        case .audio: return "Could not decode an audio track. Choose a locally available, unprotected audio file."
        case .model: return "The build needs a multilingual Whisper model."
        case .recognition: return "Whisper could not finish transcribing this recording."
        case .empty: return "No speech was recognized. Try another recording or language."
        }
    }
}

enum RecordingImport {
    // The staging directory is on the library volume so the final rename publishes audio and text together.
    static func run(file: URL, model: URL, language: SpokenLanguage, library: URL,
                    progress: (Double) -> Void) async throws -> Recording {
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let staging = library.appendingPathComponent(".import-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let audio = staging.appendingPathComponent("audio").appendingPathExtension(file.pathExtension)
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        try fm.copyItem(at: file, to: audio)
        _ = try AVAudioPlayer(contentsOf: audio)
        let text = try await transcribe(audio, model: model, language: language, progress: progress)
        try text.write(to: staging.appendingPathComponent("transcript.lrc"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        let raw = file.deletingPathExtension().lastPathComponent
        let title = String(raw.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        let stem = title.isEmpty ? "Recording" : title
        var destination = library.appendingPathComponent(stem)
        var suffix = 1
        while fm.fileExists(atPath: destination.path) {
            suffix += 1
            destination = library.appendingPathComponent("\(stem) (\(suffix))")
        }
        try fm.moveItem(at: staging, to: destination)
        return Recording(directory: destination)
    }

    private static func transcribe(_ url: URL, model: URL, language: SpokenLanguage,
                                   progress: (Double) -> Void) async throws -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RecordingError.audio }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw RecordingError.audio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecordingError.audio }
        defer { reader.cancelReading() }
        var configuration = whisper_context_default_params()
        #if targetEnvironment(simulator)
        configuration.use_gpu = false
        #endif
        guard let context = whisper_init_from_file_with_params(model.path, configuration) else { throw RecordingError.model }
        defer { whisper_free(context) }
        guard whisper_is_multilingual(context) != 0 else { throw RecordingError.model }
        var lines = [String]()
        var samples = [Float]()
        var start = 0.0
        func recognize() throws {
            try Task.checkCancellation()
            guard !samples.isEmpty else { return }
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.translate = false
            params.no_context = true
            params.n_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
            params.print_progress = false
            params.print_realtime = false
            params.token_timestamps = true
            params.split_on_word = true
            params.max_len = 100
            let status = language.rawValue.withCString { lang in
                params.language = lang
                return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
            }
            guard status == 0 else { throw RecordingError.recognition }
            for index in 0..<whisper_full_n_segments(context) {
                let text = String(cString: whisper_full_get_segment_text(context, index))
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                guard !text.isEmpty else { continue }
                let cs = max(0, Int((start * 100).rounded()) + Int(whisper_full_get_segment_t0(context, index)))
                lines.append(String(format: "[%02d:%02d.%02d]", cs / 6000, cs / 100 % 60, cs % 100) + text)
            }
            if duration.isFinite && duration > 0 { progress(min(1, (start + Double(samples.count)/16000) / duration)) }
            samples.removeAll(keepingCapacity: true)
        }
        // Use sample presentation times for every window, including after gaps or seeks in the source timeline.
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard pts.isFinite, let block = CMSampleBufferGetDataBuffer(buffer) else { throw RecordingError.audio }
            if !samples.isEmpty && abs(pts - start - Double(samples.count)/16000) > 0.02 { try recognize() }
            if samples.isEmpty { start = pts }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes % MemoryLayout<Float>.size == 0 else { throw RecordingError.audio }
            var batch = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            guard !batch.isEmpty else { continue }
            let status = batch.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw RecordingError.audio }
            samples.append(contentsOf: batch)
            if samples.count >= 16000 * 60 { try recognize() }
        }
        guard reader.status == .completed else { throw reader.error ?? RecordingError.audio }
        try recognize()
        guard !lines.isEmpty else { throw RecordingError.empty }
        return lines.joined(separator: "\n") + "\n"
    }
}
