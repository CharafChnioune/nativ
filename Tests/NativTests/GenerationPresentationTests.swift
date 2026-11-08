import AppKit
import AVFoundation
import Foundation
import SwiftUI
import NativServerKit
import XCTest

private final class GenerationFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let requestLock = NSLock()
    nonisolated(unsafe) static var methods: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestLock.withLock { Self.methods.append(request.httpMethod ?? "GET") }
        let path = request.url!.path
        let body: String
        if path.hasSuffix("/info") { body = #"{"store_id":"native-test-store","contract_version":1,"modality":"music","limits":{}}"# }
        else if path.hasSuffix("/models") {
            body = #"{"items":[{"id":"local","modality":"music","provider":"test","deployment":"local","profile_revision":"1","display_name":"Local","model":"local","qualification":"unqualified","readiness":"ready","capabilities":{"seed":true,"vocals":true,"lyrics":true,"lyrics_required_for_vocals":true,"duration":{"semantics":"target","minimum":10,"maximum":60}},"defaults":{"duration_seconds":30,"instrumental":true,"output_format":"wav"}},{"id":"hosted","modality":"music","provider":"test-cloud","deployment":"hosted","profile_revision":"1","display_name":"Hosted","model":"hosted","qualification":"unqualified","readiness":"ready","capabilities":{"seed":false,"vocals":true,"lyrics":true,"duration":{"semantics":"prompt_only"}},"defaults":{"instrumental":true,"output_format":"mp3"}}],"next_cursor":null}"#
        } else if path.hasSuffix("/sessions") {
            body = #"{"items":[{"id":"api-session","store_id":"native-test-store","modality":"music","title":"From API","hidden":false,"created_at":1,"updated_at":2}],"next_cursor":null}"#
        } else {
            body = #"{"items":[{"job_id":"api-job","store_id":"native-test-store","session_id":"api-session","modality":"music","state":"queued","stage":"waiting_for_compute","progress":null,"created_at":1,"updated_at":2,"request":{"prompt":"From API","model":"local"},"profile":{},"revision":1}],"next_cursor":null}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        let timed = body.replacingOccurrences(of: "\"created_at\":1", with: "\"created_at\":" + String(Date().timeIntervalSince1970 - 10)).replacingOccurrences(of: "\"profile\":{}", with: "\"profile\":{\"deployment\":\"local\"}")
        client?.urlProtocol(self, didLoad: Data(timed.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class MusicPresentationStateTests: XCTestCase {
    private final class HintFixtureProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url!.path
            let body: String
            if path.hasSuffix("/info") { body = #"{"store_id":"hint-test-store","contract_version":1,"modality":"music","limits":{}}"# }
            else if path.hasSuffix("/models") {
                body = #"{"items":[{"id":"ace","modality":"music","provider":"acestep","deployment":"local","profile_revision":"1","display_name":"ACE","model":"ace","qualification":"unqualified","readiness":"ready","capabilities":{"options":["bpm","key","time_signature"],"duration":{"semantics":"target"}},"defaults":{"duration_seconds":30,"instrumental":true,"output_format":"wav"}},{"id":"other","modality":"music","provider":"other","deployment":"hosted","profile_revision":"1","display_name":"Other","model":"other","qualification":"unqualified","readiness":"ready","capabilities":{"options":[],"duration":{"semantics":"prompt_only"}},"defaults":{"instrumental":true,"output_format":"mp3"}}],"next_cursor":null}"#
            } else { body = #"{"items":[],"next_cursor":null}"# }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    func testAdvertisedMusicalHintsValidateAndCannotCarryIntoAnotherProvider() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HintFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = GenerationLibraryObserver(modality: .music, journal: .init(url: directory.appendingPathComponent("intents.json")), outbox: .init(url: directory.appendingPathComponent("outbox.json")), makeClient: { NativGenerationClient(modality: $0, connection: $1, session: session) })
        let model = MusicGenerationViewModel(library: library, playback: .init(audio: .init()))
        library.connect(.init(baseURL: URL(string: "https://hints.invalid")!, apiKey: "fixture"))
        defer { library.connect(nil) }
        for _ in 0..<1_000 { if !library.profiles.isEmpty { break }; try await Task.sleep(for: .milliseconds(2)) }
        model.selectProfile("ace"); model.prompt = "A quiet piano piece"
        let automatic = try model.request()
        XCTAssertNil(automatic["bpm"]); XCTAssertNil(automatic["key"]); XCTAssertNil(automatic["time_signature"])
        model.bpmText = "120"; model.musicalKey = "F# minor"; model.timeSignature = "6"
        let hinted = try model.request()
        XCTAssertEqual(hinted["bpm"]?.integerValue, 120)
        XCTAssertEqual(hinted["key"]?.stringValue, "F# minor")
        XCTAssertEqual(hinted["time_signature"]?.stringValue, "6")
        for invalid in ["29", "301", "120.5", "fast"] {
            model.bpmText = invalid
            XCTAssertThrowsError(try model.request()) { XCTAssertEqual(($0 as? GenerationAPIError)?.field, "bpm") }
        }
        model.bpmText = "120"; model.musicalKey = String(repeating: "a", count: 33)
        XCTAssertThrowsError(try model.request()) { XCTAssertEqual(($0 as? GenerationAPIError)?.field, "key") }
        model.musicalKey = "C major"; model.timeSignature = "5"
        XCTAssertThrowsError(try model.request()) { XCTAssertEqual(($0 as? GenerationAPIError)?.field, "time_signature") }
        model.selectProfile("other")
        XCTAssertTrue(model.bpmText.isEmpty); XCTAssertTrue(model.musicalKey.isEmpty); XCTAssertTrue(model.timeSignature.isEmpty)
        // Even stale hidden values must be omitted according to capabilities.
        model.bpmText = "120"; model.musicalKey = "C major"; model.timeSignature = "4"
        let other = try model.request()
        XCTAssertNil(other["bpm"]); XCTAssertNil(other["key"]); XCTAssertNil(other["time_signature"])
    }
    func testTwoWindowsShareAPIJobButKeepDraftsAndSelectionIndependentWithoutAutoplayOrSubmission() async throws {
        GenerationFixtureProtocol.requestLock.withLock { GenerationFixtureProtocol.methods = [] }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GenerationFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = GenerationLibraryObserver(modality: .music, journal: .init(url: directory.appendingPathComponent("intents.json")), outbox: .init(url: directory.appendingPathComponent("outbox.json")), makeClient: { NativGenerationClient(modality: $0, connection: $1, session: session) })
        let player = GenerationPlaybackCoordinator(audio: .init())
        let first = MusicGenerationViewModel(library: library, playback: player)
        let second = MusicGenerationViewModel(library: library, playback: player)
        library.connect(.init(baseURL: URL(string: "https://example.invalid")!, apiKey: "fixture"))
        defer { library.connect(nil) }
        for _ in 0..<1_000 { if !library.profiles.isEmpty { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(first.jobs.first?.jobID, "api-job")
        XCTAssertEqual(second.jobs.first?.jobID, "api-job")
        first.prompt = "First window"; second.prompt = "Second window"
        first.selectedSessionID = "api-session"
        XCTAssertNil(second.selectedSessionID)
        XCTAssertEqual(first.prompt, "First window"); XCTAssertEqual(second.prompt, "Second window")
        XCTAssertFalse(player.isPlaying); XCTAssertNil(player.activeID)
        XCTAssertFalse(GenerationFixtureProtocol.requestLock.withLock { GenerationFixtureProtocol.methods.contains { $0 != "GET" } })
        first.selectProfile("local"); first.seedText = "42"; first.instrumental = false; first.lyrics = "[Verse]\n  Keep my spacing  \n"
        let local = try first.request()
        XCTAssertEqual(local["lyrics"]?.stringValue, first.lyrics)
        XCTAssertEqual(local["seed"]?.numberValue, 42)
        first.seedText = "9007199254740993"
        let wideSeed = try first.request()
        let encoded = try JSONEncoder().encode(wideSeed)
        let decoded = try JSONDecoder().decode([String: GenerationJSONValue].self, from: encoded)
        XCTAssertEqual(decoded["seed"]?.integerValue, 9_007_199_254_740_993)
        first.selectProfile("hosted"); first.allowRemote = true
        let hosted = try first.request()
        XCTAssertNil(hosted["seed"]); XCTAssertNil(hosted["duration_seconds"])
        XCTAssertEqual(hosted["allow_remote"]?.boolValue, true)
        if let path = ProcessInfo.processInfo.environment["NATIV_MEDIA_SCREENSHOT_DIR"] {
            first.selectProfile("local")
            try GenerationRenderEvidence.capture(viewModel: first, mode: .music, directory: URL(fileURLWithPath: path))
        }
    }
}

final class GenerationArtifactTests: XCTestCase {
    func testAudioClassificationAndStoreScopedIdentityDoNotAliasExistingFiles() {
        XCTAssertEqual(ArtifactKind.resolve(mimeType: "audio/mpeg", filename: "song.mp3"), .audio)
        XCTAssertEqual(ArtifactKind.resolve(mimeType: "video/mp4", filename: "clip.mp4"), .video)
        XCTAssertNotEqual(GenerationArtifactProjection.stableID(storeID: "a", assetID: "same-id"), GenerationArtifactProjection.stableID(storeID: "b", assetID: "same-id"))
        XCTAssertEqual(GenerationArtifactProjection.stableID(storeID: "a", assetID: "same-id"), GenerationArtifactProjection.stableID(storeID: "a", assetID: "same-id"))
    }
    func testOldArtifactJSONStillDecodesWithoutGenerationMetadata() throws {
        let id = UUID()
        let artifact = Artifact(id: id, kind: .image, source: .generated, sessionID: UUID(), messageID: UUID(), filename: "old.png", mimeType: "image/png", relativePath: "old.png", byteSize: 1, createdAt: Date(), prompt: nil, sessionTitle: "Old")
        let decoded = try JSONDecoder().decode(Artifact.self, from: JSONEncoder().encode(artifact))
        XCTAssertNil(decoded.serviceReference)
        XCTAssertEqual(decoded.workspace, .imageGeneration)
    }
}

final class ChatGenerationToolTests: XCTestCase {
    func testModelCannotSelectEndpointOrPaidFallbackAndToolReturnsOnlyAReference() throws {
        let call = MLXChatToolCall(id: "call", function: .init(name: "generate_video", arguments: #"{"prompt":"boat","endpoint":"https://evil.invalid"}"#))
        XCTAssertThrowsError(try ChatGenerationToolArguments.decode(call, modality: .video))
        let reference = GenerationChatJobReference(storeID: "store", jobID: "job", sessionID: "session", modality: .video)
        let content = String(decoding: try JSONEncoder().encode(reference), as: UTF8.self)
        XCTAssertEqual(GenerationChatJobReference.parse(content), reference)
        XCTAssertFalse(content.contains("apiKey")); XCTAssertFalse(content.contains("https://"))
    }
}

final class GenerationAttachmentTests: XCTestCase {
    func testGeneratedMP4IsAServiceReferenceAndNeverAnImageOrIndependentMediaOriginal() throws {
        let reference = GenerationServiceReference(storeID: "store", assetID: "video", jobID: "job", sessionID: "session", modality: "video", filename: "clip.mp4", mimeType: "video/mp4", byteSize: 1024)
        let attachment = ChatImageAttachment(serviceReference: reference)
        XCTAssertEqual(attachment.chatAttachmentKind, .generatedMedia)
        XCTAssertNil(attachment.asset); XCTAssertNil(attachment.imageData)
        let message = ChatTranscriptMessage(role: .user, content: "Use this result", imageAttachments: [attachment])
        XCTAssertEqual(ChatWorkAttachments.available(in: [message]).first?.serviceReference, reference)
        let decoded = try JSONDecoder().decode(ChatImageAttachment.self, from: JSONEncoder().encode(attachment))
        XCTAssertEqual(decoded.serviceReference, reference)
        XCTAssertNil(decoded.asset)
        XCTAssertEqual(ChatAttachmentValidator.immediateValidation(for: decoded), .ready)
    }
}

@MainActor
final class VideoPresentationStateTests: XCTestCase {
    func testAnimateCreatesOnlyAnImmutableDraftAndNoAutoplay() throws {
        let library = GenerationLibraryObserver(modality: .video)
        let playback = GenerationPlaybackCoordinator(audio: .init())
        let model = VideoGenerationViewModel(library: library, playback: playback)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<8 { for y in 0..<12 { bitmap.setColor(.systemTeal, atX: x, y: y) } }
        let original = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        model.animate(image: original, filename: "still.png")
        let snapshot = try XCTUnwrap(model.firstFrame)
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        XCTAssertEqual(model.operation, "image_to_video")
        XCTAssertEqual(try Data(contentsOf: snapshot), original)
        XCTAssertTrue(model.jobs.isEmpty); XCTAssertFalse(model.isSubmitting)
        XCTAssertFalse(model.referencesArePrepared); XCTAssertFalse(model.canSubmit)
        XCTAssertNil(playback.activeID); XCTAssertFalse(playback.isPlaying)
        if let path = ProcessInfo.processInfo.environment["NATIV_MEDIA_SCREENSHOT_DIR"] {
            try GenerationRenderEvidence.capture(viewModel: model, mode: .video, directory: URL(fileURLWithPath: path))
        }
        XCTAssertEqual(GenerationPresetDescription.label(["width": .number(704), "height": .number(448), "frame_count": .number(97), "fps": .number(24)]), "704 × 448 · 97 frames at 24 fps · approximately 4.04 seconds")
    }
    func testRemoteConnectionRequiresHTTPSOrDeliberatePrivateDevelopmentHTTP() throws {
        XCTAssertThrowsError(try GenerationServerProfile.remote(name: "Public", url: "http://example.com", allowPrivateHTTP: true))
        XCTAssertThrowsError(try GenerationServerProfile.remote(name: "Credentials", url: "https://token@example.com", allowPrivateHTTP: false))
        XCTAssertNoThrow(try GenerationServerProfile.remote(name: "Private", url: "http://192.168.1.3:8080", allowPrivateHTTP: true))
        XCTAssertNoThrow(try GenerationServerProfile.remote(name: "Secure", url: "https://example.com", allowPrivateHTTP: false))
    }
}

@MainActor
private enum GenerationRenderEvidence {
    static func capture(viewModel: GenerationWorkspaceModel, mode: ChatWorkspaceMode, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, width, scheme) in [("light", 860.0, ColorScheme.light), ("dark-narrow", 620.0, ColorScheme.dark)] {
            let root = GenerationWorkspaceView(model: NativModel(), viewModel: viewModel, mode: mode, onSelectMode: { _ in }, connectsOnAppear: false)
                .environment(\.colorScheme, scheme)
            let hosting = NSHostingView(rootView: root)
            let frame = NSRect(x: 0, y: 0, width: width, height: 780)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting; hosting.frame = frame; hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { XCTFail("Native workspace did not render"); continue }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(mode.rawValue.lowercased() + "-" + name + ".png"))
            window.close()
        }
    }
}

final class VideoInputPreviewTests: XCTestCase {
    func testCanonicalPreviewDigestAndFrozenRecipeMatchSharedPythonGolden() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/GenerationInputTransform")
        let metadata = try JSONDecoder().decode([String: GenerationJSONValue].self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        let sha = try XCTUnwrap(metadata["sha256"]?.stringValue)
        let size = try XCTUnwrap(metadata["byte_size"]?.numberValue)
        let transform = try XCTUnwrap(metadata["transform"]?.objectValue)
        let previewURL = fixtures.appendingPathComponent("canonical.png")
        let valid = try await GenerationPreparedReference.verify(url: previewURL, sha256: sha, byteSize: Int64(size))
        XCTAssertTrue(valid)
        let prepared = GenerationPreparedReference(storeID: "same-store", inputID: "immutable-original", derivativeID: "canonical-derivative", sha256: sha, byteSize: Int64(size), role: "first_frame", signature: "frozen-draft", transform: transform, previewURL: previewURL)
        let request = try XCTUnwrap(prepared.requestValue.objectValue)
        XCTAssertEqual(request.keys.sorted(), ["input_id", "role", "transform"])
        XCTAssertEqual(request["input_id"]?.stringValue, "immutable-original")
        XCTAssertEqual(request["transform"]?.objectValue, transform)
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: corrupt) }
        var bytes = try Data(contentsOf: previewURL); bytes[bytes.count - 1] ^= 1
        try bytes.write(to: corrupt)
        let corrupted = try await GenerationPreparedReference.verify(url: corrupt, sha256: sha, byteSize: Int64(size))
        XCTAssertFalse(corrupted, "A same-size corrupted preview must never be presented as the canonical derivative")
    }
}


@MainActor
final class GenerationPlaybackTests: XCTestCase {
    func testActualVideoMarkersDecodeAndSeekWithNativeAudio() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let encoder = root.appendingPathComponent("dist/codec-runtime/bin/ffmpeg")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: encoder.path), "The required managed media build must precede native tests")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nativ-video-marker-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("markers.mp4")
        let rawVideo = temporary.appendingPathComponent("frames.rgb"), rawAudio = temporary.appendingPathComponent("stereo.pcm")
        var frames = Data(), samples = Data()
        for frame in 0..<24 {
            for y in 0..<64 {
                for x in 0..<96 { frames.append(contentsOf: [UInt8((x * 2 + frame * 7) % 256), UInt8(y * 4), UInt8(frame * 10)]) }
            }
        }
        for index in 0..<48_000 {
            var sample = Int16(12_000 * sin(2 * Double.pi * 880 * Double(index) / 48_000)).littleEndian
            withUnsafeBytes(of: &sample) { bytes in samples.append(contentsOf: bytes); samples.append(contentsOf: bytes) }
        }
        try frames.write(to: rawVideo); try samples.write(to: rawAudio)
        let process = Process(); process.executableURL = encoder
        process.arguments = ["-nostdin", "-v", "error", "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "96x64", "-framerate", "24", "-i", rawVideo.path, "-f", "s16le", "-ar", "48000", "-ac", "2", "-i", rawAudio.path, "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-y", output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { XCTFail("Managed marker encoding failed: \(process.terminationStatus)"); return }
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.05)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, 1)
        let rate = try await XCTUnwrap(videoTracks.first).load(.nominalFrameRate)
        XCTAssertEqual(rate, 24)
        let generator = AVAssetImageGenerator(asset: asset)
        var decodedFrames: [Data] = []
        for seconds in [0.0, 0.5, 0.95] {
            let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            XCTAssertEqual(result.image.width, 96); XCTAssertEqual(result.image.height, 64)
            decodedFrames.append(try XCTUnwrap(result.image.dataProvider?.data) as Data)
        }
        XCTAssertNotEqual(decodedFrames[0], decodedFrames[1]); XCTAssertNotEqual(decodedFrames[1], decodedFrames[2])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item); player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        for _ in 0..<100 {
            if item.status != .unknown { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(item.status, .readyToPlay)
        let sought = await player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(sought); XCTAssertEqual(player.currentTime().seconds, 0.5, accuracy: 1.0 / 24)
    }
    func testRealDecodedWaveformAndPlaybackPauseBeforeMicrophoneGrant() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("scripts/tests/fixtures/generation-audio/tone-440hz-stereo.mp3")
        let media = AVURLAsset(url: url)
        let duration = try await media.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        let peaks = try await GenerationWaveform.peaks(url: url)
        XCTAssertFalse(peaks.isEmpty)
        XCTAssertTrue(peaks.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        XCTAssertTrue(peaks.contains { $0 > 0 })
        let audio = AudioSessionCoordinator()
        let playback = GenerationPlaybackCoordinator(audio: audio)
        playback.volume = 0 // Exercise the actual AVPlayer path without emitting test audio.
        XCTAssertFalse(playback.isPlaying)
        await playback.play(id: "fixture", title: "Fixture", url: url)
        XCTAssertTrue(playback.isPlaying)
        let microphone = try await audio.acquire(owner: .init(name: "Translate fixture"), resources: [.microphone])
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.player.rate, 0)
        XCTAssertTrue(audio.isActive(microphone))
        audio.release(microphone)
        XCTAssertFalse(playback.isPlaying, "Recording completion must not automatically resume media")
        await playback.resume()
        XCTAssertTrue(playback.isPlaying, "The compact player can resume only after an explicit action")
        playback.clear()
        await playback.resume()
        XCTAssertFalse(playback.isPlaying)
    }
}
