import Foundation
import NativExtensionSDK
import SwiftUI

@MainActor
final class LiveTranslationExtension: NativHostExtension {
    static let identifier = "io.github.charafchnioune.nativ.translation"
    static let pageID = identifier + ".page"
    let coordinator = LiveTranslationCoordinator()
    let manifest: NativExtensionManifest

    init(bundle: Bundle = .main) {
        let url = bundle.resourceURL?.appendingPathComponent("LiveTranslation/Manifest.json")
        manifest = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(NativExtensionManifest.self, from: $0) }
            ?? NativExtensionManifest(
                id: Self.identifier, version: "1.0.0", minimumNativVersion: "1.0.0", displayName: "Translate",
                summary: "Private local translation of spoken turns.", developer: "Nativ fork contributors",
                systemImage: "bubble.left.and.text.bubble.right", included: true, enabledByDefault: false,
                runtime: .extensionFoundation, extensionPoint: "io.github.charafchnioune.nativ.nativ-extension",
                runtimeBundleIdentifier: "io.github.charafchnioune.nativ.LiveTranslationExtension",
                contributions: .init(sidebar: [.init(id: Self.pageID, title: "Translate", systemImage: "bubble.left.and.text.bubble.right", order: 260)],
                                     commands: [.init(id: Self.identifier + ".toggle", title: "Toggle translation"),
                                                .init(id: Self.identifier + ".stop", title: "Stop translation")]),
                permissions: [.microphone, .systemAudioCapture, .modelsSpeechToText, .overlay, .namespacedStorage])
    }
    func activate(context: NativExtensionHostContext) {
        coordinator.configurationProvider = context.transcriptionConfiguration
        coordinator.cascadeBackendProvider = { settings, endpoint in
            guard let configuration = context.transcriptionConfiguration() else { throw CancellationError() }
            return try await TranslationCascadeProviders.make(settings: settings, endpoint: endpoint,
                                                               configuration: configuration, audioServer: context.audioServer)
        }
        coordinator.recognitionPreparationProvider = { settings in
            guard let configuration = context.transcriptionConfiguration() else { throw CancellationError() }
            _ = try await TranslationCascadeProviders.prepareRecognition(settings: settings, configuration: configuration)
        }
        coordinator.activate()
    }
    func deactivate() {
        coordinator.deactivate()
        coordinator.configurationProvider = nil
        coordinator.cascadeBackendProvider = nil
        coordinator.recognitionPreparationProvider = nil
    }
    func makePage(id: String, context: NativExtensionPageContext) -> AnyView? {
        guard id == Self.pageID else { return nil }
        return AnyView(LiveTranslationView(coordinator: coordinator, model: context.model,
                                          titleLeadingInset: context.titleLeadingInset, openModels: context.openSpeechModels))
    }
    func performCommand(id: String) {
        switch id {
        case Self.identifier + ".toggle": coordinator.toggle()
        case Self.identifier + ".stop": coordinator.stop()
        default: break
        }
    }
}
