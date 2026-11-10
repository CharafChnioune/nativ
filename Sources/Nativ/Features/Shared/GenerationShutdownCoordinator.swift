import AppKit
import Foundation
import NativServerKit

/// Applies only to the app-owned embedded server. Disconnecting remote Nativ profiles never stops them.
@MainActor
final class GenerationShutdownCoordinator {
    func confirmAndPrepareStop(connection: GenerationConnection?, reason: String) async -> Bool {
        guard let connection else { return true }
        do {
            let discovery = NativGenerationClient(modality: .music, connection: connection)
            let info = try await discovery.info()
            let client = NativGenerationClient(modality: .music, connection: connection.bound(to: info.storeID))
            let state = try await client.serverState()
            let pending = Int(state["pending_count"]?.numberValue ?? 0)
            if pending > 0 {
                let alert = NSAlert()
                alert.messageText = "\(reason) with \(pending) generation \(pending == 1 ? "job" : "jobs")?"
                alert.informativeText = "This stops the embedded Nativ server. Active local generation is interrupted; undispatched queued jobs require Resume after restart. Saved originals remain intact. Remote providers may continue execution and charge your account. Nativ never automatically resubmits uncertain requests."
                alert.addButton(withTitle: "Keep Server Running")
                alert.addButton(withTitle: reason)
                guard alert.runModal() == .alertSecondButtonReturn else { return false }
            }
            var prepared = try await client.prepareStop()
            let deadline = Date().addingTimeInterval(45)
            while prepared["ready_to_stop"]?.boolValue != true, Date() < deadline {
                try await Task.sleep(for: .milliseconds(250))
                prepared = try await client.serverState()
            }
            if prepared["ready_to_stop"]?.boolValue != true {
                let alert = NSAlert(); alert.messageText = "Generation cleanup is still running"
                alert.informativeText = "Nativ is waiting for its owned generation workers to stop. Try again after cleanup finishes."
                alert.addButton(withTitle: "Keep Running"); alert.runModal()
                return false
            }
            return true
        } catch {
            // A stopped/unreachable control service cannot be queried. The process controller's
            // bounded shutdown and worker parent-death guard remain the final ownership boundary.
            return true
        }
    }
}
