import Combine
import MediaPlayer
import UIKit

enum PlaybackActivity {
    case playing
    case paused
}

struct ObservedTrack {
    let title: String
    let artwork: UIImage?
    let elapsedSeconds: TimeInterval
    let durationSeconds: TimeInterval
    let activity: PlaybackActivity
}

enum PlayerViewState {
    case requestingAuthorization
    case authorizationDenied
    case idle
    case unmatched(ObservedTrack)
    case bound(track: ObservedTrack, transcript: LyricTranscript, activeLineIndex: Int?)
}

@MainActor
final class MusicFollower: NSObject, ObservableObject {
    @Published private(set) var state: PlayerViewState = .requestingAuthorization

    private let player: MPMusicPlayerController
    private let catalog: TranscriptCatalog
    private var timer: Timer?
    private var notificationsStarted = false
    private var cachedTitle: String?
    private var cachedArtwork: UIImage?
    private var cachedResolution: TranscriptResolution?

    init(
        player: MPMusicPlayerController = .systemMusicPlayer,
        catalog: TranscriptCatalog = .live()
    ) {
        self.player = player
        self.catalog = catalog
        super.init()
    }

    func start() {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            startObservingPlayer()
        case .notDetermined:
            state = .requestingAuthorization
            MPMediaLibrary.requestAuthorization { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.start()
                }
            }
        case .denied, .restricted:
            state = .authorizationDenied
        @unknown default:
            state = .authorizationDenied
        }
    }

    func playPause() {
        if player.playbackState == .playing {
            player.pause()
        } else {
            player.play()
        }
        refresh()
    }

    func skipToPreviousTrack() {
        player.skipToPreviousItem()
        invalidateTrackCache()
        refresh()
    }

    func skipToNextTrack() {
        player.skipToNextItem()
        invalidateTrackCache()
        refresh()
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let requestedTime = max(0, seconds)
        player.currentPlaybackTime = requestedTime
        refresh(playbackTimeOverride: requestedTime)
    }

    private func startObservingPlayer() {
        if !notificationsStarted {
            player.beginGeneratingPlaybackNotifications()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerItemChanged),
                name: .MPMusicPlayerControllerNowPlayingItemDidChange,
                object: player
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerStateChanged),
                name: .MPMusicPlayerControllerPlaybackStateDidChange,
                object: player
            )
            notificationsStarted = true
        }

        if timer == nil {
            let refreshTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
            RunLoop.main.add(refreshTimer, forMode: .common)
            timer = refreshTimer
        }
        refresh()
    }

    @objc private func playerItemChanged() {
        invalidateTrackCache()
        refresh()
    }

    @objc private func playerStateChanged() {
        refresh()
    }

    private func invalidateTrackCache() {
        cachedTitle = nil
        cachedArtwork = nil
        cachedResolution = nil
    }

    private func refresh(playbackTimeOverride: TimeInterval? = nil) {
        guard let item = player.nowPlayingItem,
              let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            invalidateTrackCache()
            state = .idle
            return
        }

        if cachedTitle != title || cachedResolution == nil {
            cachedTitle = title
            cachedArtwork = item.artwork?.image(at: CGSize(width: 240, height: 240))
            cachedResolution = catalog.resolve(trackTitle: title)
        }

        let duration = finiteNonnegative(item.playbackDuration)
        let observedTime = playbackTimeOverride ?? player.currentPlaybackTime
        let elapsed = min(finiteNonnegative(observedTime), duration > 0 ? duration : .greatestFiniteMagnitude)
        let track = ObservedTrack(
            title: title,
            artwork: cachedArtwork,
            elapsedSeconds: elapsed,
            durationSeconds: duration,
            activity: player.playbackState == .playing ? .playing : .paused
        )

        switch cachedResolution {
        case let .matched(transcript):
            let adjustedTime = elapsed + PlaybackTiming.globalOffsetSeconds
            state = .bound(
                track: track,
                transcript: transcript,
                activeLineIndex: transcript.activeLineIndex(at: adjustedTime)
            )
        case .missing, .ambiguous, .unreadable, .none:
            state = .unmatched(track)
        }
    }

    private func finiteNonnegative(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}
