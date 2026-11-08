import SwiftUI

struct GenerationLocalMediaPreview: View {
    let url: URL
    var isVideo = false
    @ObservedObject private var playback = GenerationPlaybackCoordinator.shared
    var body: some View {
        VStack(spacing: 18) {
            if isVideo, playback.activeID == url.absoluteString {
                GenerationVideoSurface(playback: playback).frame(minHeight: 220, maxHeight: 500)
            } else { Image(systemName: isVideo ? "film" : "waveform").font(.system(size: 52)).foregroundStyle(.secondary) }
            Button(playback.isPlaying && playback.activeID == url.absoluteString ? "Pause" : "Play") {
                if playback.isPlaying && playback.activeID == url.absoluteString { playback.pause() }
                else { Task { await playback.play(id: url.absoluteString, title: url.lastPathComponent, url: url) } }
            }.buttonStyle(.borderedProminent)
            Text(url.lastPathComponent).font(.caption)
        }
        .onDisappear { if playback.activeID == url.absoluteString { playback.clear() } }
    }
}
