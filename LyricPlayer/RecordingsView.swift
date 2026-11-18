import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct RecordingsView: View {
    @State private var language: SpokenLanguage = .english
    @State private var picking = false
    @State private var recordings: [Recording] = []
    @State private var path = [Recording]()
    @State private var job: Task<Void, Never>?
    @State private var progress = 0.0
    @State private var error: String?

    private var library: URL {
        URL.documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Transcribe a recording") {
                    Picker("Spoken language", selection: $language) {
                        ForEach(SpokenLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(job != nil)
                    if job != nil {
                        ProgressView("Transcribing on this iPhone…", value: progress)
                        Button("Cancel") { job?.cancel() }
                    } else {
                        Button("Choose Audio…", systemImage: "waveform") { picking = true }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Section("Saved recordings") {
                    if recordings.isEmpty { Text("Choose a file to create a timed transcript.").foregroundStyle(.secondary) }
                    ForEach(recordings) { item in
                        NavigationLink(item.title, value: item)
                    }
                }
            }
            .navigationTitle("LyricPlayer")
            .navigationDestination(for: Recording.self) { RecordingReview(recording: $0) }
            .onAppear { reload() }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.audio]) { result in
                do { try begin(result.get()) }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func reload() {
        do { recordings = try Recording.list(in: library) }
        catch { self.error = error.localizedDescription }
    }

    private func begin(_ url: URL) throws {
        guard job == nil else { return }
        guard let model = Bundle.main.url(forResource: "ggml-base", withExtension: "bin") else {
            throw RecordingError.model
        }
        error = nil
        progress = 0
        let chosen = language, root = library
        job = Task {
            defer { job = nil }
            do {
                let item = try await RecordingImport.run(file: url, model: model, language: chosen, library: root) { value in
                    Task { @MainActor in progress = value }
                }
                reload()
                path = [item]
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct RecordingReview: View {
    let recording: Recording
    @State private var player: AVAudioPlayer?
    @State private var transcript: LyricTranscript?
    @State private var error: String?

    var body: some View {
        Group {
            if let player, let transcript {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let active = transcript.activeLineIndex(at: player.currentTime)
                    VStack {
                        TranscriptView(lines: transcript.lines, activeLineIndex: active) { line in
                            player.currentTime = line.timestampSeconds
                            player.play()
                        }
                        Slider(value: Binding(get: { player.currentTime }, set: { player.currentTime = $0 }),
                               in: 0...max(player.duration, 0.01))
                            .accessibilityLabel("Playback position")
                        Button(player.isPlaying ? "Pause" : "Play") {
                            if player.isPlaying { player.pause() } else { player.play() }
                        }.buttonStyle(.borderedProminent)
                    }.padding()
                }
            } else if let error { Text(error) }
            else { ProgressView() }
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do {
                guard let url = recording.audio else { throw RecordingError.audio }
                let audio = try AVAudioPlayer(contentsOf: url)
                let text = try String(contentsOf: recording.transcript, encoding: .utf8)
                let parsed = LyricTranscript.parse(contents: text, title: NormalizedTrackTitle(recording.title) ?? NormalizedTrackTitle("Recording")!)
                guard !parsed.lines.isEmpty else { throw RecordingError.empty }
                try AVAudioSession.sharedInstance().setCategory(.playback)
                player = audio
                transcript = parsed
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { player?.stop() }
    }
}
