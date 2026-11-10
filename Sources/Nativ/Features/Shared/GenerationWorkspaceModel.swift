import AppKit
import Combine
import Foundation
import NativServerKit
import UniformTypeIdentifiers

@MainActor
class GenerationWorkspaceModel: ObservableObject {
    let library: GenerationLibraryObserver
    let playback: GenerationPlaybackCoordinator
    @Published var prompt = ""
    @Published var lyrics = ""
    @Published var instrumental = true
    @Published private(set) var selectedProfileID = ""
    @Published var selectedSessionID: String?
    @Published var duration: Double = 30
    @Published var seedText = ""
    @Published var bpmText = ""
    @Published var musicalKey = ""
    @Published var timeSignature = ""
    @Published var operation = "text_to_video" { didSet {
        if operation != oldValue, profile != nil, !availableOutputPresets.contains(outputPreset) { outputPreset = availableOutputPresets.first ?? "" }
    } }
    @Published var outputPreset = "" { didSet {
        if outputPreset != oldValue { preparedReferences = [:] }
        if let first = availableDurations.first, !availableDurations.contains(Int64(exactly: duration) ?? -1) { duration = Double(first) }
    } }
    @Published var audioMode = "silent"
    @Published var allowRemote = false
    @Published var firstFrame: URL? { didSet { if firstFrame != oldValue { preparedReferences = [:] } } }
    @Published var lastFrame: URL? { didSet { if lastFrame != oldValue { preparedReferences = [:] } } }
    @Published var fitPolicy = "contain" { didSet { if fitPolicy != oldValue { preparedReferences = [:] } } }
    @Published private(set) var preparedReferences: [String: GenerationPreparedReference] = [:]
    @Published private(set) var isPreparingReferences = false
    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?
    private var storeChange: AnyCancellable?
    private var selectionStoreID: String?
    private var libraryChange: AnyCancellable?
    init(library: GenerationLibraryObserver, playback: GenerationPlaybackCoordinator = .shared) {
        self.library = library; self.playback = playback
        storeChange = library.$storeID.sink { [weak self] storeID in
            guard let self, selectionStoreID != storeID else { return }
            selectionStoreID = storeID; selectedSessionID = nil; selectedProfileID = ""; allowRemote = false; preparedReferences = [:]
        }
        libraryChange = library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var modality: GenerationModality { library.modality }
    var profile: GenerationProfile? { library.profiles.first { $0.id == selectedProfileID } }
    var availableDurations: [Int64] {
        profile?.capabilities["presets"]?.objectValue?[outputPreset]?.objectValue?["duration_options"]?.arrayValue?.compactMap(\.integerValue) ?? []
    }
    var availableOutputPresets: [String] {
        (profile?.capabilities["presets"]?.objectValue ?? [:]).filter { _, value in
            let required = value.objectValue?["operation"]?.stringValue
            return required == nil || required == operation
        }.keys.sorted()
    }
    var jobs: [GenerationJob] { library.jobs.filter { selectedSessionID == nil || $0.sessionID == selectedSessionID } }
    var visibleSessions: [GenerationSession] { library.sessions.filter { !$0.hidden } }
    var canSubmit: Bool { !isSubmitting && !isPreparingReferences && referencesArePrepared && library.isConnected && library.storeID != nil && profile?.readiness == "ready" && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (profile?.deployment == "local" || allowRemote) }
    func selectProfile(_ id: String) {
        selectedProfileID = id; preparedReferences = [:]
        guard let profile else { return }
        allowRemote = false; seedText = ""; bpmText = ""; musicalKey = ""; timeSignature = ""
        instrumental = profile.defaults["instrumental"]?.boolValue ?? true
        duration = profile.defaults["duration_seconds"]?.numberValue ?? profile.defaults["duration"]?.numberValue ?? 30
        outputPreset = profile.defaults["output_preset"]?.stringValue ?? ""
        audioMode = profile.defaults["audio_mode"]?.stringValue ?? "silent"
        if !profile.stringList("operations").contains(operation) { operation = profile.stringList("operations").first ?? "text_to_video" }
        if !profile.stringList("input_roles").contains("last_frame") { lastFrame = nil }
    }
    func applyInitialProfile() {
        guard profile == nil else { return }
        // Only a ready local profile is selected automatically. Remote choices remain explicit.
        if let candidate = library.profiles.first(where: { $0.deployment == "local" && $0.readiness == "ready" }) { selectProfile(candidate.id) }
    }
    func newDraft() { selectedSessionID = nil; prompt = ""; lyrics = ""; firstFrame = nil; lastFrame = nil; errorMessage = nil }
    func animate(image: Data, filename: String) {
        newDraft()
        if let target = Self.animationProfileID(current: profile, among: library.profiles) { selectProfile(target) }
        operation = "image_to_video"
        do { firstFrame = try snapshot(data: image, filename: filename) } catch { errorMessage = error.localizedDescription }
    }
    /// Some profiles are text-to-video only (LTX-2.3); animating a still moves to a ready local profile that accepts a first frame.
    static func animationProfileID(current: GenerationProfile?, among profiles: [GenerationProfile]) -> String? {
        guard current?.stringList("operations").contains("image_to_video") != true else { return nil }
        return profiles.first { $0.deployment == "local" && $0.readiness == "ready" && $0.stringList("operations").contains("image_to_video") }?.id
    }
    func chooseImage(last: Bool = false) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .webP]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 25 * 1024 * 1024 else { throw GenerationAPIError(code: "input_size", message: "Choose a still image smaller than 25 MiB.") }
            let imported = try snapshot(data: Data(contentsOf: url), filename: url.lastPathComponent)
            if last { lastFrame = imported } else { firstFrame = imported; operation = "image_to_video" }
        } catch { errorMessage = error.localizedDescription }
    }
    private func snapshot(data: Data, filename: String) throws -> URL {
        guard data.count <= 25 * 1024 * 1024 else { throw GenerationAPIError(code: "input_size", message: "Choose a still image smaller than 25 MiB.") }
        let url = GenerationPersistence.directory.appendingPathComponent("Draft Inputs").appendingPathComponent(UUID().uuidString).appendingPathComponent((filename as NSString).lastPathComponent)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic); return url
    }
    func request() throws -> [String: GenerationJSONValue] {
        guard let profile else { throw GenerationAPIError(code: "model_required", message: "Choose a configured model first.") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GenerationAPIError(code: "prompt_required", message: "Enter a description.") }
        var request: [String: GenerationJSONValue] = ["model": .string(profile.id), "prompt": .string(prompt), "allow_remote": .bool(allowRemote)]
        if let selectedSessionID { request["session_id"] = .string(selectedSessionID) }
        if profile.capabilities["seed"]?.boolValue == true, !seedText.isEmpty {
            let maximum: Int64 = modality == .video ? 4_294_967_295 : profile.provider == "stable_audio_cloud" ? 4_294_967_294 : Int64.max
            guard let seed = Int64(seedText), (0...maximum).contains(seed) else { throw GenerationAPIError(code: "invalid_seed", message: "Seed must be a whole number between 0 and \(maximum).", field: "seed") }
            request["seed"] = .integer(seed)
        }
        if modality == .music {
            let options = Set(profile.stringList("options"))
            if options.contains("bpm"), !bpmText.isEmpty {
                guard let bpm = Int64(bpmText), (30...300).contains(bpm) else {
                    throw GenerationAPIError(code: "invalid_control", message: "Tempo hint must be a whole number between 30 and 300 BPM.", field: "bpm")
                }
                request["bpm"] = .integer(bpm)
            }
            if options.contains("key"), !musicalKey.isEmpty {
                guard musicalKey.unicodeScalars.count <= 32 else {
                    throw GenerationAPIError(code: "invalid_control", message: "Use a musical key hint of at most 32 characters.", field: "key")
                }
                request["key"] = .string(musicalKey)
            }
            if options.contains("time_signature"), !timeSignature.isEmpty {
                guard ["2", "3", "4", "6"].contains(timeSignature) else {
                    throw GenerationAPIError(code: "invalid_control", message: "Choose a time signature hint of 2, 3, 4 or 6.", field: "time_signature")
                }
                request["time_signature"] = .string(timeSignature)
            }
            request["instrumental"] = .bool(instrumental)
            if !instrumental, profile.capabilities["lyrics"]?.boolValue == true {
                if profile.capabilities["lyrics_required_for_vocals"]?.boolValue == true, lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw GenerationAPIError(code: "lyrics_required", message: "This vocal model requires your lyrics.", field: "lyrics")
                }
                request["lyrics"] = .string(lyrics)
            }
            if let semantics = profile.capabilities["duration"]?.objectValue?["semantics"]?.stringValue, semantics != "prompt_only" { request["duration_seconds"] = .number(duration) }
            if let format = profile.defaults["output_format"] { request["output_format"] = format }
        } else {
            request["operation"] = .string(operation); request["output_preset"] = .string(outputPreset); request["audio_mode"] = .string(audioMode)
            if profile.defaults["duration"] != nil {
                guard duration.isFinite, (1...380).contains(duration), duration.rounded() == duration else {
                    throw GenerationAPIError(code: "invalid_duration", message: "Choose a whole-number video duration supported by this provider.", field: "duration")
                }
                let seconds = Int64(duration)
                guard availableDurations.isEmpty || availableDurations.contains(seconds) else {
                    throw GenerationAPIError(code: "unsupported_duration", message: "Choose a duration advertised for this model and preset.", field: "duration")
                }
                request["duration"] = .integer(seconds)
            }
        }
        return request
    }
    var referencePreparationSignature: String {
        let preset = profile?.capabilities["presets"]?.objectValue?[outputPreset]?.objectValue ?? [:]
        let values = [library.storeID ?? "", selectedProfileID, outputPreset, String(preset["width"]?.numberValue ?? 0), String(preset["height"]?.numberValue ?? 0), firstFrame?.absoluteString ?? "", lastFrame?.absoluteString ?? "", fitPolicy]
        return GenerationMediaCache.key(values.joined(separator: "|"))
    }
    var referencesArePrepared: Bool {
        guard modality == .video, operation == "image_to_video" else { return true }
        guard firstFrame != nil, preparedReferences["first_frame"]?.signature == referencePreparationSignature else { return false }
        return lastFrame == nil || preparedReferences["last_frame"]?.signature == referencePreparationSignature
    }
    func prepareReferences() async {
        guard !isPreparingReferences, let profile, let connection = library.connection, let storeID = library.storeID,
              let firstFrame, let preset = profile.capabilities["presets"]?.objectValue?[outputPreset]?.objectValue,
              let width = preset["width"]?.numberValue, let height = preset["height"]?.numberValue,
              width.isFinite, height.isFinite, (1...8192).contains(width), (1...8192).contains(height), width.rounded() == width, height.rounded() == height else {
            errorMessage = "Choose a model, output preset and first frame before preparing the reference."; return
        }
        isPreparingReferences = true; errorMessage = nil
        defer { isPreparingReferences = false }
        let signature = referencePreparationSignature
        let transform: [String: GenerationJSONValue] = ["version": .number(1), "fit_policy": .string(fitPolicy), "crop": .null, "background": .string("#000000")]
        let client = NativGenerationClient(modality: .video, connection: connection)
        do {
            var prepared: [String: GenerationPreparedReference] = [:]
            for (role, source) in [("first_frame", Optional(firstFrame)), ("last_frame", lastFrame)] {
                guard let source else { continue }
                let input = try await client.uploadInput(file: source)
                guard let inputID = input["input_id"]?.stringValue else { throw GenerationAPIError(code: "invalid_input", message: "The server did not return an immutable input identity.") }
                let derivative = try await client.prepareInput(inputID: inputID, width: Int(width), height: Int(height), transform: transform)
                guard signature == referencePreparationSignature, library.storeID == storeID else { throw CancellationError() }
                guard derivative["store_id"]?.stringValue == storeID, derivative["input_id"]?.stringValue == inputID,
                      let recipe = derivative["transform"]?.objectValue, recipe["version"]?.integerValue == 1,
                      recipe["fit_policy"]?.stringValue == fitPolicy, recipe["crop"] == .null, recipe["background"]?.stringValue == "#000000",
                      derivative["color_space"]?.stringValue == "sRGB", derivative["encoding"]?.stringValue == "RGB PNG", let id = derivative["derivative_id"]?.stringValue,
                      let sha = derivative["sha256"]?.stringValue, let size = derivative["byte_size"]?.numberValue, size.isFinite, (1...167_772_160).contains(size), size.rounded() == size,
                      derivative["width"]?.numberValue == width, derivative["height"]?.numberValue == height else {
                    throw GenerationAPIError(code: "invalid_reference_preview", message: "The server returned a reference preview for a different store or output size.")
                }
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent(NativBuildIdentity.applicationSupportDirectoryName).appendingPathComponent("Video Input Previews")
                let preview = directory.appendingPathComponent(GenerationMediaCache.key(storeID + ":" + id + ":" + sha) + ".png")
                _ = try await client.downloadInputDerivative(inputID: inputID, derivativeID: id, to: preview)
                guard try await GenerationPreparedReference.verify(url: preview, sha256: sha, byteSize: Int64(size)) else {
                    throw GenerationAPIError(code: "corrupt_reference_preview", message: "The reference preview did not match its canonical content digest. Prepare it again.")
                }
                prepared[role] = GenerationPreparedReference(storeID: storeID, inputID: inputID, derivativeID: id, sha256: sha, byteSize: Int64(size), role: role, signature: signature, transform: transform, previewURL: preview)
            }
            guard signature == referencePreparationSignature, library.storeID == storeID else { throw CancellationError() }
            preparedReferences = prepared
        } catch is CancellationError { errorMessage = "The reference changed while preparing. Prepare the new selection before generating." }
        catch { errorMessage = error.localizedDescription }
    }
    func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true; errorMessage = nil
        defer { isSubmitting = false }
        do {
            var accepted = try request()
            if modality == .video, operation == "image_to_video" {
                guard referencesArePrepared else { throw GenerationAPIError(code: "reference_preview_required", message: "Prepare and review the canonical reference preview before generating.") }
                accepted["inputs"] = .array(["first_frame", "last_frame"].compactMap { preparedReferences[$0]?.requestValue })
            }
            let job = try await library.submit(accepted, intentID: UUID().uuidString)
            selectedSessionID = job.sessionID
        } catch { errorMessage = error.localizedDescription }
    }
    func regenerate(_ job: GenerationJob) async {
        do {
            let fields: Set<String> = ["model", "prompt", "session_id", "allow_remote", "output_format", "lyrics", "instrumental", "duration_seconds", "duration", "seed", "steps", "shift", "bpm", "key", "time_signature", "operation", "output_preset", "audio_mode", "inputs"]
            let request = job.submittedRequest ?? job.request.filter { fields.contains($0.key) }
            _ = try await library.submit(request, intentID: UUID().uuidString)
        } catch { errorMessage = error.localizedDescription }
    }
    func action(_ action: String, job: GenerationJob) async {
        do { try await library.mutate(job: job, action: action) } catch { errorMessage = error.localizedDescription }
    }
    func play(_ job: GenerationJob) async {
        guard let id = job.assetID, let asset = library.assets[id] else { return }
        if playback.activeID == job.storeID + ":" + id, playback.isPlaying { playback.pause(); return }
        do {
            let url = try await library.mediaURL(asset: asset)
            await playback.play(id: job.storeID + ":" + id, title: job.request["prompt"]?.stringValue ?? modality.rawValue.capitalized, url: url)
        } catch { errorMessage = error.localizedDescription }
    }
    func export(_ job: GenerationJob) async {
        guard let id = job.assetID, let asset = library.assets[id] else { return }
        do {
            let url = try await library.mediaURL(asset: asset)
            let panel = NSSavePanel(); panel.nameFieldStringValue = (asset.filename as NSString).lastPathComponent
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let scoped = destination.startAccessingSecurityScopedResource(); defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            try SafeLocalFileReader.exportCopy(from: url, to: destination)
        } catch { errorMessage = error.localizedDescription }
    }
}

extension GenerationProfile {
    func stringList(_ key: String) -> [String] { capabilities[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var deploymentLabel: String { deployment == "local" ? "Local on Nativ server" : deployment == "remote_gpu" ? "Remote GPU" : "Hosted provider" }
    var readinessLabel: String { (readiness ?? "configuration_required").replacingOccurrences(of: "_", with: " ").capitalized }
}
