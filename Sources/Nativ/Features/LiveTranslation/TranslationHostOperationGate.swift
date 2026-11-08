import Foundation

/// A host operation may suspend while Stop, Mute, or a newer command takes ownership.
/// Revalidate at both sides of every suspension before applying its result.
@MainActor
final class TranslationHostOperationGate {
    struct Token: Hashable, Sendable { fileprivate let id = UUID() }
    private(set) var current = Token()
    @discardableResult func invalidate() -> Token { current = Token(); return current }
    func isCurrent(_ token: Token) -> Bool { token == current }
    func check(_ token: Token) throws {
        guard isCurrent(token), !Task.isCancelled else { throw CancellationError() }
    }
    func perform<T: Sendable>(token: Token, _ operation: @MainActor () async throws -> T) async throws -> T {
        try check(token)
        do {
            let result = try await operation()
            try check(token)
            return result
        } catch {
            try check(token)
            throw error
        }
    }
}
