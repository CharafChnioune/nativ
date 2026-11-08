import AppKit
import SwiftUI

struct NativApplicationCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.nativWindowState) private var focusedWindow

    let appDelegate: AppDelegate

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Nativ · Live Translate fork") {
                let info = Bundle.main.infoDictionary ?? [:]
                let upstream = info["NativUpstreamSHA"] as? String ?? "Unavailable"
                let revision = info["NativForkRevision"] as? String ?? "development"
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .applicationName: "Nativ · Live Translate fork",
                    .credits: NSAttributedString(string:
                        "\(NativBuildIdentity.repository)\nBased on Neywa-Labs/nativ. This is an independent fork.\nUpstream: \(upstream)\nFork revision: \(revision)\nMIT notices and model/component licenses are retained in this build.")
                ])
            }
        }
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updater: appDelegate.softwareUpdater.updater)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                perform(.newChat)
            }
            .keyboardShortcut("n")

            Button("New Window", action: openNewWindow)
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                perform(.toggleSidebar)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }

        CommandGroup(after: .sidebar) {
            Button("Collapse All Sections") {
                perform(.collapseSidebarSections)
            }
            .keyboardShortcut(".", modifiers: [.command, .option])

            Button("Increase Chat Font Size") {
                appDelegate.increaseChatFontSize()
            }
            .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Chat Font Size") {
                appDelegate.decreaseChatFontSize()
            }
            .keyboardShortcut("-", modifiers: .command)
            Button("Reset Chat Font Size") {
                appDelegate.resetChatFontSize()
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                perform(.openTab(.settings))
            }
            .keyboardShortcut(",")
        }
    }

    private func openNewWindow() {
        openWindow(id: "main")
    }

    private func perform(_ intent: NativWindowIntent) {
        if let focusedWindow {
            focusedWindow.perform(intent)
        } else {
            appDelegate.performWindowIntent(intent)
        }
    }
}
