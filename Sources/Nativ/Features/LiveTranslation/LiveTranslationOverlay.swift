import AppKit
import Combine
import SwiftUI

@MainActor
final class LiveTranslationOverlay {
    private let panel: NSPanel
    private let animationPreferences: VoiceAnimationPreferences
    private weak var coordinator: LiveTranslationCoordinator?
    private var screenObserver: NSObjectProtocol?
    private var styleObservation: AnyCancellable?
    init(coordinator: LiveTranslationCoordinator, animationPreferences: VoiceAnimationPreferences? = nil) {
        self.coordinator = coordinator
        self.animationPreferences = animationPreferences ?? .shared
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 156),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        NativAudioOverlayLayout.configure(panel, interactive: true)
        panel.isMovableByWindowBackground = true
        panel.setAccessibilityLabel("Live Translate controls")
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.position() } }
        styleObservation = self.animationPreferences.$selectedStyle.removeDuplicates().dropFirst().sink { [weak self] style in
            // @Published emits before storage changes; use its value after hopping to the main actor.
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.position(style: style)
            }
        }
    }
    func show() {
        guard let coordinator else { return }
        // Reattach only while visible: no hidden TimelineView continues animating.
        if panel.contentView == nil { panel.contentView = NSHostingView(rootView: TranslationOverlayContent(coordinator: coordinator)) }
        if !panel.isVisible { position(); panel.orderFrontRegardless() }
    }
    func hide() { panel.orderOut(nil); panel.contentView = nil }
    private func position(style: VoiceCaptureAnimationStyle? = nil) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NativAudioOverlayLayout.screen(containing: pointer) else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let preferred: NSPoint
        switch style ?? animationPreferences.selectedStyle {
        case .cursorWaveform:
            preferred = NSPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height - 18)
        case .gradientIsland:
            preferred = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12)
        case .notchShelf:
            // Keep the interactive card below the camera rather than hiding controls in its cutout.
            let cameraCenter: CGFloat
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
               right.minX - left.maxX > 20 {
                cameraCenter = (left.maxX + right.minX) / 2
            } else {
                cameraCenter = visible.midX
            }
            preferred = NSPoint(x: cameraCenter - size.width / 2, y: visible.maxY - size.height - 8)
        case .verticalRecorder:
            preferred = NSPoint(x: visible.maxX - size.width - 12, y: visible.midY - size.height / 2)
        }
        panel.setFrameOrigin(NativAudioOverlayLayout.clampedOrigin(preferred, size: panel.frame.size, visibleFrame: screen.visibleFrame))
    }
    isolated deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        panel.orderOut(nil)
    }
}

private struct TranslationOverlayContent: View {
    @ObservedObject var coordinator: LiveTranslationCoordinator
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TranslationOverlayActivity(level: coordinator.isSpeaking ? coordinator.outputLevel : coordinator.inputLevel,
                    isSpeaking: coordinator.isSpeaking, isListening: coordinator.isListening)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Translate").legacyTextStyle(.compactCardTitle)
                        TranslationOverlayLanguagePair(settings: coordinator.settings)
                    }
                    Text(coordinator.status).legacyTextStyle(.metadata).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: coordinator.stop) { Image(systemName: "stop.fill") }.help("Stop translation").accessibilityLabel("Stop translation")
            }
            Text(coordinator.translatedText.isEmpty ? "Speech and captions stay on this Mac." : coordinator.translatedText)
                .legacyTextStyle(.body).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(coordinator.state == .running ? "Pause" : "Resume", action: coordinator.toggle)
                Button(coordinator.isMuted ? "Unmute" : "Mute", action: coordinator.toggleMute)
                Spacer()
                Button("Interrupt speech", action: coordinator.interruptSpeech).disabled(coordinator.state != .running)
            }.controlSize(.small)
        }
        .padding(16)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 22).fill(Color(nsColor: .windowBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: 22).fill(.regularMaterial)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(reduceTransparency ? 0.2 : 0.08)))
        .padding(6)
    }
}

private struct TranslationOverlayLanguagePair: View {
    @ObservedObject var settings: LiveTranslationSettings
    var body: some View {
        let source = settings.value.sourceLanguage
        let target = settings.value.targetLanguage
        let direction = "\(Locale.current.localizedString(forLanguageCode: source) ?? source) → \(Locale.current.localizedString(forLanguageCode: target) ?? target)"
        Text("\(source.uppercased()) → \(target.uppercased())")
            .legacyTextStyle(.metadata).foregroundStyle(.secondary).lineLimit(1)
            .help(direction).accessibilityLabel(direction)
    }
}

private struct TranslationOverlayActivity: View {
    let level: Float
    let isSpeaking: Bool
    let isListening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var meterLevel: Float { level.isFinite ? min(1, max(0, level)) : 0 }
    var body: some View {
        Group {
            if (isListening || isSpeaking) && !reduceMotion && !reduceTransparency {
                VoiceGradientOrb(level: meterLevel, isRecording: true)
                    .animation(NativAudioOverlayLayout.levelAnimation, value: meterLevel)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: isSpeaking ? "speaker.wave.2" : "waveform")
                    if isListening || isSpeaking {
                        Capsule().fill(.secondary)
                            .frame(width: 28, height: 3)
                            .overlay(alignment: .leading) {
                                Capsule().fill(.primary).frame(width: 28 * CGFloat(meterLevel), height: 3)
                            }
                            .animation(reduceMotion ? nil : NativAudioOverlayLayout.levelAnimation, value: meterLevel)
                    }
                }
            }
        }
        .frame(width: 32, height: 32).accessibilityHidden(true)
    }
}
