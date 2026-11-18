import SwiftUI

@main
struct LyricPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                RecordingsView().tabItem { Label("Recordings", systemImage: "waveform") }
                MusicTab().tabItem { Label("Music", systemImage: "music.note") }
            }
        }
    }
}

private struct MusicTab: View {
    @State private var opened = false
    var body: some View {
        Group {
            if opened { ContentView() } else { Color.clear }
        }
        .onAppear { opened = true }
    }
}

private struct ContentView: View {
    @StateObject private var follower = MusicFollower()

    var body: some View {
        Group {
            switch follower.state {
            case .requestingAuthorization:
                ProgressView("Requesting Music access…")
            case .authorizationDenied:
                ContentUnavailableView(
                    "Music Access Required",
                    systemImage: "music.note",
                    description: Text("Allow LyricPlayer to read your media library in Settings.")
                )
            case .idle:
                ContentUnavailableView(
                    "Nothing Playing",
                    systemImage: "text.quote",
                    description: Text("Start a track in Music to follow its transcript here.")
                )
            case let .unmatched(track):
                PlayerScreen(track: track, follower: follower) {
                    ContentUnavailableView(
                        "No transcript for this track",
                        systemImage: "doc.questionmark",
                        description: Text("Add an LRC file whose name exactly matches the track title.")
                    )
                }
            case let .bound(track, transcript, activeLineIndex):
                PlayerScreen(track: track, follower: follower) {
                    TranscriptView(lines: transcript.lines, activeLineIndex: activeLineIndex)
                        .id(transcript.title)
                }
            }
        }
        .task {
            follower.start()
        }
    }
}

private struct PlayerScreen<Content: View>: View {
    let track: ObservedTrack
    @ObservedObject var follower: MusicFollower
    @ViewBuilder let content: Content

    init(
        track: ObservedTrack,
        follower: MusicFollower,
        @ViewBuilder content: () -> Content
    ) {
        self.track = track
        self.follower = follower
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 16) {
            TrackHeader(track: track)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PlaybackControls(track: track, follower: follower)
        }
        .padding()
    }
}

private struct TrackHeader: View {
    let track: ObservedTrack

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let artwork = track.artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "book.closed.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(track.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TranscriptView: View {
    let lines: [LyricLine]
    let activeLineIndex: Int?
    var seek: ((LyricLine) -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(lines.indices, id: \.self) { index in
                        Group {
                            if let seek {
                                Button { seek(lines[index]) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        let seconds = Int(lines[index].timestampSeconds)
                                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                                            .font(.caption.monospacedDigit())
                                        Text(lines[index].text)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            } else {
                                Text(lines[index].text)
                            }
                        }
                            .font(.title2)
                            .fontWeight(index == activeLineIndex ? .bold : .regular)
                            .foregroundStyle(index == activeLineIndex ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                index == activeLineIndex ? Color.accentColor.opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .id(index)
                    }
                }
                .padding(.vertical)
            }
            .onChange(of: activeLineIndex, initial: true) { oldIndex, newIndex in
                guard let newIndex else { return }
                if oldIndex == newIndex {
                    proxy.scrollTo(newIndex, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct PlaybackControls: View {
    let track: ObservedTrack
    @ObservedObject var follower: MusicFollower
    @State private var isScrubbing = false
    @State private var scrubbedTime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubbedTime : track.elapsedSeconds },
                    set: { scrubbedTime = $0 }
                ),
                in: 0...max(track.durationSeconds, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubbedTime = track.elapsedSeconds
                        isScrubbing = true
                    } else {
                        isScrubbing = false
                        follower.seek(to: scrubbedTime)
                    }
                }
            )
            .disabled(track.durationSeconds <= 0)

            HStack {
                Text(formattedTime(isScrubbing ? scrubbedTime : track.elapsedSeconds))
                Spacer()
                Text(formattedTime(track.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 46) {
                Button(action: follower.skipToPreviousTrack) {
                    Image(systemName: "backward.fill")
                }
                Button(action: follower.playPause) {
                    Image(systemName: track.activity == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                }
                Button(action: follower.skipToNextTrack) {
                    Image(systemName: "forward.fill")
                }
            }
            .font(.title2)
            .buttonStyle(.plain)
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
