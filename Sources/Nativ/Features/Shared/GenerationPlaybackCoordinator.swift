import AppKit
import AVFoundation
import AVKit
import Combine
import CoreAudio
import SwiftUI

/// The only generated-media player in the app. Loading a result never starts playback.
@MainActor
final class GenerationPlaybackCoordinator: ObservableObject {
    static let shared = GenerationPlaybackCoordinator()
    @Published private(set) var activeID: String?
    @Published private(set) var title = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var volume: Double = 0.8 { didSet { player.volume = Float(volume) } }
    @Published private(set) var errorMessage: String?
    let player = AVPlayer()
    private let audio: AudioSessionCoordinator
    private var lease: AudioSessionLease?
    private let owner = AudioSessionOwner(name: "Music and Video")
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var outputChangeListener: AudioObjectPropertyListenerBlock?
    private var playbackRevision = UUID()
    private var loadedURL: URL?
    private var itemObservation: NSKeyValueObservation?

    init(audio: AudioSessionCoordinator = .shared) {
        self.audio = audio
        player.volume = Float(volume)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let seconds = self.player.currentItem?.duration.seconds ?? 0
                self.duration = seconds.isFinite ? seconds : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.pause()
            }
        }
        let outputChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.pause() }
        }
        outputChangeListener = outputChanged
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputChanged)
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }

    isolated deinit {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let outputChangeListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputChangeListener)
        }
    }

    func play(id: String, title: String, url: URL) async {
        let revision = UUID(); playbackRevision = revision
        pause(invalidate: false)
        do {
            let acquired = try await audio.acquireInterruptiblePlayback(owner: owner) { [weak self] in self?.pause() }
            guard playbackRevision == revision else { audio.release(acquired); return }
            lease = acquired
            if activeID != id {
                let item = AVPlayerItem(url: url)
                itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.player.currentItem === item else { return }
                        self.pause(); self.errorMessage = "This media file could not be played. Download the original again or inspect its format."
                    }
                }
                player.replaceCurrentItem(with: item); loadedURL = url
                activeID = id; self.title = title; position = 0; duration = 0
            }
            errorMessage = nil
            player.play(); isPlaying = true
        } catch { errorMessage = error.localizedDescription }
    }

    func pause(invalidate: Bool = true) {
        if invalidate { playbackRevision = UUID() }
        player.pause(); isPlaying = false
        if let lease { audio.release(lease); self.lease = nil }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600))
    }
    func resume() async {
        guard let id = activeID, let url = loadedURL else { return }
        await play(id: id, title: title, url: url)
    }
    func clear() { pause(); itemObservation = nil; player.replaceCurrentItem(with: nil); loadedURL = nil; activeID = nil; title = ""; position = 0; duration = 0 }
}

struct GenerationVideoSurface: NSViewRepresentable {
    @ObservedObject var playback: GenerationPlaybackCoordinator
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .none; view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true; view.player = playback.player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = playback.player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct GenerationCompactPlayer: View {
    @ObservedObject var playback: GenerationPlaybackCoordinator
    var body: some View {
        if playback.activeID != nil {
            HStack(spacing: 12) {
                Button {
                    if playback.isPlaying { playback.pause() }
                    else { Task { await playback.resume() } }
                } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }
                    .help(playback.isPlaying ? "Pause playback" : "Resume playback")
                Text(playback.title).lineLimit(1).font(.caption)
                Slider(value: Binding(get: { playback.position }, set: playback.seek), in: 0...max(1, playback.duration))
                    .accessibilityLabel("Playback position")
                Text(GenerationTime.label(playback.position)).monospacedDigit().font(.caption)
                Button { playback.clear() } label: { Image(systemName: "xmark") }.help("Close player")
                if let error = playback.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            }
            .padding(10).background(.bar)
        }
    }
}

enum GenerationTime {
    static func label(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let seconds = Int(value); return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
