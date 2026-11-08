import AppKit
import NativServerKit
import SwiftUI

struct GenerationComposer: View {
    @ObservedObject var viewModel: GenerationWorkspaceModel
    let onSetup: () -> Void
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu {
                    ForEach(viewModel.library.profiles) { profile in
                        Button { viewModel.selectProfile(profile.id) } label: {
                            Text("\(profile.displayName) · \(profile.deploymentLabel) · \(profile.readinessLabel)")
                        }
                    }
                    Divider()
                    Button("Manage providers and runtimes…", action: onSetup)
                } label: {
                    Text(viewModel.profile?.displayName ?? "Choose a model").lineLimit(1)
                }
                Spacer()
                if let profile = viewModel.profile { Text(profile.deploymentLabel).font(.caption).foregroundStyle(.secondary) }
            }
            TextField(viewModel.modality == .music ? "Describe the music…" : "Describe the video…", text: $viewModel.prompt, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(3...7).font(.body)
                .accessibilityLabel("Generation description")
            if viewModel.modality == .music { musicControls } else { videoControls }
            if let profile = viewModel.profile, profile.deployment != "local" {
                Toggle("Send this request\(viewModel.firstFrame == nil ? "" : " and reference images") to \(profile.deploymentLabel). Account charges may apply.", isOn: $viewModel.allowRemote)
                    .font(.caption)
            }
            DisclosureGroup("Advanced", isExpanded: $advanced) { advancedControls.padding(.top, 8) }.font(.caption)
            HStack {
                if let profile = viewModel.profile, profile.readiness != "ready" {
                    Button(profile.readinessLabel, action: onSetup).font(.caption)
                }
                Spacer()
                Button { Task { await viewModel.submit() } } label: {
                    HStack(spacing: 7) {
                        if viewModel.isSubmitting { ProgressView().controlSize(.mini) }
                        Text(viewModel.isSubmitting ? "Submitting…" : "Generate")
                        Image(systemName: "arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent).disabled(!viewModel.canSubmit)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
    @ViewBuilder private var musicControls: some View {
        if viewModel.profile?.capabilities["vocals"]?.boolValue == true {
            Toggle(viewModel.profile?.capabilities["instrumental_semantics"]?.stringValue == "prompt_hint" ? "Instrumental preference (prompt hint)" : "Instrumental", isOn: $viewModel.instrumental).font(.callout)
            if !viewModel.instrumental, viewModel.profile?.capabilities["lyrics"]?.boolValue == true {
                TextField("Your lyrics", text: $viewModel.lyrics, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...8).accessibilityLabel("Manual lyrics, preserved exactly")
            }
        }
    }
    private var videoControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Operation", selection: $viewModel.operation) {
                    ForEach(viewModel.profile?.stringList("operations") ?? ["text_to_video", "image_to_video"], id: \.self) { operation in
                        Text(operation == "image_to_video" ? "Image to Video" : "Text to Video").tag(operation)
                    }
                }.labelsHidden()
                if viewModel.profile != nil {
                Picker("Preset", selection: $viewModel.outputPreset) {
                    ForEach(viewModel.availableOutputPresets, id: \.self) { preset in
                        Text(preset.replacingOccurrences(of: "-", with: " ").capitalized).tag(preset)
                    }
                }.labelsHidden()
                Picker("Audio", selection: $viewModel.audioMode) {
                    ForEach(viewModel.profile?.stringList("audio_modes") ?? ["silent"], id: \.self) { mode in
                        Text(mode == "silent" ? "Silent" : "Native audio").tag(mode)
                    }
                }.labelsHidden()
                }
            }
            if let preset = viewModel.profile?.capabilities["presets"]?.objectValue?[viewModel.outputPreset]?.objectValue {
                Text(GenerationPresetDescription.label(preset)).font(.caption).foregroundStyle(.secondary)
                if viewModel.profile?.defaults["duration"] != nil { Text("Requested duration: \(viewModel.duration.formatted()) seconds").font(.caption).foregroundStyle(.secondary) }
            }
            if viewModel.operation == "image_to_video" {
                HStack(spacing: 10) {
                    reference(viewModel.firstFrame, label: "First frame", last: false)
                    if viewModel.profile?.stringList("input_roles").contains("last_frame") == true { reference(viewModel.lastFrame, label: "Last frame", last: true) }
                    Picker("Image fit", selection: $viewModel.fitPolicy) {
                        Text("Contain · black background").tag("contain")
                        Text("Crop · centered fill").tag("crop")
                    }.font(.caption)
                }
                Text("Prepare References uploads a private snapshot to your Nativ server and shows its exact provider-bound preview. Contain preserves the full image with black padding; Crop fills the frame with a centered crop. Neither stretches the image.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(viewModel.isPreparingReferences ? "Preparing…" : viewModel.referencesArePrepared ? "Prepare References Again" : "Prepare References") {
                        Task { await viewModel.prepareReferences() }
                    }.disabled(viewModel.isPreparingReferences || viewModel.firstFrame == nil || viewModel.profile == nil || !viewModel.library.isConnected)
                    if viewModel.referencesArePrepared { Label("Canonical preview ready", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private var previewAspect: Double {
        let values = viewModel.profile?.capabilities["presets"]?.objectValue?[viewModel.outputPreset]?.objectValue
        let width = values?["width"]?.numberValue ?? 1
        let height = values?["height"]?.numberValue ?? 1
        return width / max(1, height)
    }
    private func reference(_ url: URL?, label: String, last: Bool) -> some View {
        Button { viewModel.chooseImage(last: last) } label: {
            VStack(spacing: 4) {
                if let url {
                    GenerationInputPreview(url: viewModel.preparedReferences[last ? "last_frame" : "first_frame"]?.previewURL ?? url, aspect: previewAspect)
                } else { Image(systemName: "photo.badge.plus").frame(width: 80, height: 60) }
                Text(viewModel.preparedReferences[last ? "last_frame" : "first_frame"] == nil ? label : label + " · Canonical").font(.caption)
            }
        }.buttonStyle(.bordered)
    }
    @ViewBuilder private var advancedControls: some View {
        if let profile = viewModel.profile {
            if viewModel.modality == .music, let duration = profile.capabilities["duration"]?.objectValue, duration["semantics"]?.stringValue != "prompt_only" {
                HStack {
                    Text("Duration \(duration["semantics"]?.stringValue ?? "target")")
                    TextField("Seconds", value: $viewModel.duration, format: .number).frame(width: 72)
                    Text("seconds")
                }
            } else if viewModel.modality == .video, profile.defaults["duration"] != nil {
                if !viewModel.availableDurations.isEmpty {
                    Picker("Duration", selection: Binding(get: { Int64(exactly: viewModel.duration) ?? viewModel.availableDurations.first ?? 1 }, set: { viewModel.duration = Double($0) })) {
                        ForEach(viewModel.availableDurations, id: \.self) { seconds in Text("\(seconds) seconds").tag(seconds) }
                    }
                } else {
                    HStack { Text("Duration"); TextField("Seconds", value: $viewModel.duration, format: .number).frame(width: 72); Text("seconds") }
                }
            }
            if profile.capabilities["seed"]?.boolValue == true {
                HStack { Text("Seed"); TextField("Random", text: $viewModel.seedText).frame(width: 140) }
            }
            if viewModel.modality == .music {
                let options = profile.stringList("options")
                if options.contains("bpm") {
                    HStack { Text("Tempo hint"); TextField("Automatic", text: $viewModel.bpmText).frame(width: 90); Text("BPM · 30–300") }
                }
                if options.contains("key") {
                    HStack { Text("Key hint"); TextField("Automatic · e.g. C major", text: $viewModel.musicalKey) }
                }
                if options.contains("time_signature") {
                    Picker("Time signature hint", selection: $viewModel.timeSignature) {
                        Text("Automatic").tag("")
                        ForEach(["2", "3", "4", "6"], id: \.self) { value in Text(value).tag(value) }
                    }
                }
                if options.contains(where: { ["bpm", "key", "time_signature"].contains($0) }) {
                    Text("Musical hints guide generation; the resulting tempo, key and meter can vary.").foregroundStyle(.secondary)
                }
            }
            Text("Qualification: \(profile.qualification). Requested settings and measured output are recorded separately.")
                .foregroundStyle(.secondary)
        }
    }
}

enum GenerationPresetDescription {
    static func label(_ preset: [String: GenerationJSONValue]) -> String {
        let width = preset["width"]?.numberValue.map { String(Int($0)) } ?? "?"
        let height = preset["height"]?.numberValue.map { String(Int($0)) } ?? "?"
        guard let frames = preset["frame_count"]?.numberValue, let fps = preset["fps"]?.numberValue, fps > 0 else { return "\(width) × \(height) · timing determined by provider" }
        return "\(width) × \(height) · \(Int(frames)) frames at \(Int(fps)) fps · approximately \(String(format: "%.2f", frames / fps)) seconds"
    }
}
