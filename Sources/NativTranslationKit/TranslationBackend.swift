import Foundation

/// Implementations must cancel preparation cooperatively, bound their stream, and stop
/// producers on termination. Audio commitment is independent of turnCompleted. A final
/// text event is a whole-text snapshot that preserves every stableAppend prefix.
public protocol TranslationBackend: Sendable {
    func prepare(configuration: TranslationConfiguration) async throws -> TranslationCapabilities
    func start(sessionID: TranslationSessionID, generation: TranslationGeneration) async throws
        -> AsyncThrowingStream<TranslationEvent, Error>
    func send(frame: OwnedPCMFrame) async throws
    func commit(turnID: TranslationTurnID) async throws
    func cancel(turnID: TranslationTurnID) async
    func stop() async
}
