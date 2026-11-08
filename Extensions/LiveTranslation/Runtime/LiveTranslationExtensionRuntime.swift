import ExtensionFoundation
import Foundation
import NativExtensionSDK

private final class LiveTranslationRuntimeService:
    NSObject,
    NativExtensionXPCProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var activationContext: NativExtensionActivationContext?

    func activate(
        with contextData: Data,
        reply: @escaping (String?) -> Void
    ) {
        do {
            let context = try JSONDecoder().decode(
                NativExtensionActivationContext.self,
                from: contextData
            )
            guard context.extensionID == "io.github.charafchnioune.nativ.translation" else {
                reply("The activation context belongs to another extension.")
                return
            }
            lock.withLock {
                activationContext = context
            }
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    func deactivate(withReply reply: @escaping () -> Void) {
        lock.withLock {
            activationContext = nil
        }
        reply()
    }

    func performCommand(
        _ commandID: String,
        payload: Data?,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        let isActive = lock.withLock {
            activationContext != nil
        }
        guard isActive else {
            reply(nil, "Translate is not active.")
            return
        }
        reply(nil, nil)
    }
}

@main
private final class LiveTranslationExtensionRuntime: AppExtension {
    private let service = LiveTranslationRuntimeService()

    required init() {}

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(
            host: "io.github.charafchnioune.nativ",
            name: "nativ-extension"
        )
    }

    var configuration: ConnectionHandler {
        ConnectionHandler { [service] connection in
            connection.exportedInterface = NSXPCInterface(
                with: NativExtensionXPCProtocol.self
            )
            connection.exportedObject = service
            connection.remoteObjectInterface = NSXPCInterface(
                with: NativExtensionHostXPCProtocol.self
            )
            connection.resume()
            return true
        }
    }
}
