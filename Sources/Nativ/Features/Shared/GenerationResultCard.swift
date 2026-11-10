import AppKit
import AVFoundation
import NativServerKit
import SwiftUI

struct GenerationResultCard: View {
    let job: GenerationJob
    @ObservedObject var viewModel: GenerationWorkspaceModel
    @ObservedObject private var playback = GenerationPlaybackCoordinator.shared
    @State private var peaks: [Float] = []
    @State private var poster: NSImage?
    @State private var releasing = false
    @State private var working = false
    @State private var showsDetails = false
    @State private var confirmingRegeneration = false
    private var asset: GenerationAsset? { job.assetID.flatMap { viewModel.library.assets[$0] } }
    private var unresolvedReservation: Bool { job.remoteReservation == "reserved" && [.submissionUnknown, .cancelled, .cancelRequested].contains(job.state) }
    private var waveformPeaks: [Float] {
        let measured = asset?.metadata["waveform"]?.arrayValue?.prefix(256).compactMap { $0.numberValue }.filter { $0.isFinite }.map { Float(max(0, min(1, $0))) } ?? []
        return measured.isEmpty ? peaks : measured
    }
    private var deploymentTitle: String {
        switch job.profile["deployment"]?.stringValue {
        case "local": "Local · Nativ server"
        case "remote_gpu": "Remote GPU"
        case "hosted": "Hosted provider"
        default: "Deployment unavailable"
        }
    }
    private var active: Bool { playback.activeID == job.storeID + ":" + (job.assetID ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(job.request["prompt"]?.stringValue ?? "Generation").font(.body).textSelection(.enabled)
            HStack {
                Text(job.profile["display_name"]?.stringValue ?? job.request["model"]?.stringValue ?? "Model").font(.caption.weight(.semibold))
                Spacer()
                Text(deploymentTitle).font(.caption).foregroundStyle(.secondary)
            }
            if let asset, !asset.trashed, job.state == .succeeded { completed(asset) } else { status }
            DisclosureGroup("Generation details", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Job \(job.jobID)").textSelection(.enabled)
                    Text("\(job.state.rawValue) · \(job.stage.replacingOccurrences(of: "_", with: " "))")
                    if let lyrics = job.request["lyrics"]?.stringValue, !lyrics.isEmpty { Text(lyrics).textSelection(.enabled) }
                    if let generated = asset?.metadata["provider_reported"]?.objectValue?["generated_lyrics"]?.stringValue, !generated.isEmpty {
                        Text("Generated lyrics").font(.caption.weight(.semibold))
                        Text(generated).textSelection(.enabled)
                    }
                    if let data = try? JSONEncoder().encode(job.effectiveParameters ?? job.request), let value = String(data: data, encoding: .utf8) {
                        Text(value).textSelection(.enabled).font(.caption.monospaced())
                    }
                    if let asset {
                        Text("Original · \(asset.mimeType) · \(ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file))")
                    }
                    if job.state.isTerminal {
                        Button("Regenerate as a new job") {
                            if job.profile["deployment"]?.stringValue == "local" { Task { await viewModel.regenerate(job) } }
                            else { confirmingRegeneration = true }
                        }
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.caption)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .confirmationDialog("Release the remote reservation?", isPresented: $releasing) {
            Button("Acknowledge possible ongoing execution and charges") { Task { await viewModel.action("release", job: job) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This frees Nativ's reserved capacity. It does not stop provider execution, cancel charges or make resubmission safe.") }
        .confirmationDialog("Create a new external generation?", isPresented: $confirmingRegeneration) {
            Button("Send again and accept possible new charges") { Task { await viewModel.regenerate(job) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This sends the original prompt and references to the selected provider as a new job. Existing provider work may still be running. Account charges may apply again.") }
        .task(id: asset?.assetID) { await loadPoster() }
        .task(id: active) { await loadWaveform() }
        .onDisappear { if job.modality == .video, active { playback.pause() } }
    }
    @ViewBuilder private func completed(_ asset: GenerationAsset) -> some View {
        if job.modality == .video {
            if active {
                GenerationVideoSurface(playback: playback).frame(minHeight: 200, maxHeight: 420).clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let poster {
                Image(nsImage: poster).resizable().scaledToFit().frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 180)
            }
        } else if !waveformPeaks.isEmpty {
            GenerationWaveformView(peaks: waveformPeaks, fraction: active && playback.duration > 0 ? playback.position / playback.duration : 0)
        }
        HStack(spacing: 12) {
            Button {
                working = true
                Task { await viewModel.play(job); working = false }
            } label: {
                if working { ProgressView().controlSize(.mini) }
                else { Label(active && playback.isPlaying ? "Pause" : "Play", systemImage: active && playback.isPlaying ? "pause.fill" : "play.fill") }
            }.disabled(working).buttonStyle(.bordered)
            if let duration = asset.metadata["duration"]?.numberValue ?? asset.metadata["duration_seconds"]?.numberValue {
                Text(GenerationTime.label(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if job.modality == .video, let width = asset.metadata["width"]?.numberValue, let height = asset.metadata["height"]?.numberValue {
                Text("\(Int(width)) × \(Int(height))").font(.caption).foregroundStyle(.secondary)
            }
            if job.modality == .video { Text(asset.metadata["audio"]?.objectValue == nil ? "Silent" : "Native audio").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Menu {
                Button("Remove this session usage and move unused original to Trash", role: .destructive) {
                    Task { do { try await viewModel.library.removeSessionUsageAndTrash(job: job) } catch { viewModel.errorMessage = error.localizedDescription } }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            if job.modality == .video {
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Toggle full screen")
            }
            Button("Export Original") { Task { await viewModel.export(job) } }.buttonStyle(.bordered)
        }
        if active {
            HStack(spacing: 10) {
                Text(GenerationTime.label(playback.position)).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { playback.position }, set: { playback.seek($0) }), in: 0...max(1, playback.duration)).accessibilityLabel("Playback position")
                Text("−" + GenerationTime.label(max(0, playback.duration - playback.position))).font(.caption.monospacedDigit())
                Image(systemName: playback.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                Slider(value: $playback.volume, in: 0...1).frame(width: 80).accessibilityLabel("Volume")
            }
        }
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !job.state.isTerminal, job.state != .recoveryHold, job.state != .submissionUnknown { ProgressView().controlSize(.small) }
                Text(GenerationPresentation.status(job)).foregroundStyle(job.error == nil ? Color.secondary : .orange)
            }
            if let progress = job.progress, progress.isFinite, (0...1).contains(progress), !job.state.isTerminal {
                ProgressView(value: progress).accessibilityLabel("\(job.stage) progress")
            }
            if !job.state.isTerminal {
                HStack(spacing: 4) { Text("Submitted"); Text(Date(timeIntervalSince1970: job.createdAt), style: .relative); Text("ago") }.font(.caption).foregroundStyle(.secondary)
            }
            if let error = job.error { Text(error.message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if job.state == .submissionUnknown || unresolvedReservation {
                Text("The provider may still be working and charging your account. This request will not be automatically submitted again.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if job.state == .recoveryHold { Button("Resume") { Task { await viewModel.action("resume", job: job) } } }
                if job.state == .retrievalPending { Button("Retry Download") { Task { await viewModel.action("retry-download", job: job) } } }
                if !job.state.isTerminal, job.state != .cancelRequested { Button("Cancel") { Task { await viewModel.action("cancel", job: job) } } }
                if unresolvedReservation { Button("Release remote reservation…") { releasing = true } }
                if let asset, asset.trashed {
                    Text("Original is in Trash").font(.caption)
                    Button("Restore Original") { Task { do { try await viewModel.library.restore(asset: asset) } catch { viewModel.errorMessage = error.localizedDescription } } }
                }
            }.buttonStyle(.bordered)
        }
    }
    private func loadPoster() async {
        guard job.modality == .video, let asset, let connection = viewModel.library.connection, asset.storeID == connection.storeID else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("generation-poster-" + GenerationMediaCache.key(asset.storeID + asset.assetID) + ".jpg")
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = try? await NativGenerationClient(modality: .video, connection: connection).download(assetID: asset.assetID, to: url, poster: true)
        }
        guard !Task.isCancelled else { return }
        poster = NSImage(contentsOf: url)
    }
    private func loadWaveform() async {
        guard active, job.modality == .music, waveformPeaks.isEmpty, let asset else { return }
        guard let url = await GenerationMediaCache.shared.cachedURL(for: asset) else { return }
        if let values = try? await GenerationWaveformCache.shared.peaks(for: url), !Task.isCancelled { peaks = values }
    }
}

enum GenerationPresentation {
    static func status(_ job: GenerationJob) -> String {
        switch job.state {
        case .queued: return job.stage == "waiting_for_memory" ? "Waiting for memory" : "Queued · waiting for compute"
        case .recoveryHold: return "Waiting for Resume after restart"
        case .preparing: return "Preparing model"
        case .running: return job.stage.replacingOccurrences(of: "_", with: " ").capitalized
        case .finalizing: return job.modality == .music ? "Validating and writing audio" : "Encoding and importing video"
        case .retrievalPending: return "Existing generation · retrieval needs attention"
        case .succeeded: return "Completed"
        case .cancelRequested: return "Cancellation requested"
        case .cancelled: return job.remoteReservation == "reserved" ? "Observation cancelled · provider stop unconfirmed" : "Cancelled"
        case .interrupted: return "Interrupted · Regenerate creates a new job"
        case .failed: return "Generation failed"
        case .submissionUnknown: return "Remote outcome is uncertain"
        }
    }
}
