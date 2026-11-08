import AppKit
import SwiftUI

/// Geometry shared by dictation and Translate; safe on external displays and Spaces.
@MainActor
enum NativAudioOverlayLayout {
    nonisolated static let dismissalDuration: TimeInterval = 0.38
    static let levelAnimation: Animation = .easeOut(duration: 0.12)
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
    static func clampedOrigin(_ preferred: NSPoint, size: NSSize, visibleFrame: NSRect, inset: CGFloat = 8) -> NSPoint {
        NSPoint(x: max(visibleFrame.minX + inset, min(preferred.x, visibleFrame.maxX - size.width - inset)),
                y: max(visibleFrame.minY + inset, min(preferred.y, visibleFrame.maxY - size.height - inset)))
    }
    static func configure(_ panel: NSPanel, interactive: Bool) {
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = false
        panel.ignoresMouseEvents = !interactive; panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    }
}
