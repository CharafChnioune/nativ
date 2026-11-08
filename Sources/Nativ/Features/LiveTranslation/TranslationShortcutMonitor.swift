import AppKit
import Carbon.HIToolbox

@MainActor
final class TranslationShortcutMonitor {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    fileprivate var action: (() -> Void)?
    fileprivate static let signature: OSType = 0x4E54524C

    func start(shortcut: VoiceShortcut, action: @escaping () -> Void) throws {
        stop()
        guard let keyCode = shortcut.keyCode, !shortcut.modifiers.isEmpty,
              shortcut != VoiceShortcutPreferences.shared.recordShortcut,
              shortcut != VoiceShortcutPreferences.shared.retryShortcut else {
            throw Failure.invalid
        }
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), translationHotKeyHandler, 1, &event,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { stop(); throw Failure.unavailable }
        let registered = RegisterEventHotKey(UInt32(keyCode), shortcut.modifiers.carbonFlags,
            EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else { stop(); throw Failure.unavailable }
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil; action = nil
    }
    isolated deinit { stop() }
    enum Failure: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: "Choose a keyed shortcut with a modifier that differs from the Audio shortcuts."
            case .unavailable: "This shortcut is already in use or unavailable. Choose another shortcut."
            }
        }
    }
}

private func translationHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let data else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard result == noErr else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<TranslationShortcutMonitor>.fromOpaque(data).takeUnretainedValue()
    return MainActor.assumeIsolated {
        guard id.signature == TranslationShortcutMonitor.signature else { return OSStatus(eventNotHandledErr) }
        monitor.action?()
        return noErr
    }
}
