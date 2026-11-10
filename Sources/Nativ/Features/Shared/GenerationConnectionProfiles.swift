import Combine
import Foundation
import NativServerKit

struct GenerationServerProfile: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case localEmbedded, remoteConfigured }
    let id: String
    let name: String
    let kind: Kind
    let baseURL: URL?
    let allowPrivateHTTP: Bool
    static let embedded = Self(id: "local-embedded", name: "This Mac · Embedded Nativ server", kind: .localEmbedded, baseURL: nil, allowPrivateHTTP: false)
    static func remote(name: String, url: String, allowPrivateHTTP: Bool) throws -> Self {
        guard let components = URLComponents(string: url), let parsed = components.url,
              let host = components.host?.lowercased(), !host.isEmpty, components.user == nil,
              components.password == nil, components.query == nil, components.fragment == nil,
              components.scheme == "https" || (allowPrivateHTTP && components.scheme == "http" && isPrivate(host)) else {
            throw GenerationAPIError(code: "invalid_server_url", message: "Use an HTTPS Nativ server URL without credentials, query or fragment. Private HTTP requires the explicit development option.")
        }
        return .init(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : name, kind: .remoteConfigured, baseURL: parsed, allowPrivateHTTP: allowPrivateHTTP)
    }
    private static func isPrivate(_ host: String) -> Bool {
        if ["localhost", "::1", "127.0.0.1"].contains(host) { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}

/// The active profile is immutable; editing a remote endpoint creates a new identity.
@MainActor
final class GenerationConnectionProfiles: ObservableObject {
    static let shared = GenerationConnectionProfiles()
    @Published private(set) var profiles: [GenerationServerProfile] = [.embedded]
    @Published private(set) var selectedID = GenerationServerProfile.embedded.id
    private let url: URL
    init(url: URL = GenerationPersistence.directory.appendingPathComponent("server-profiles.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            profiles = [.embedded] + saved.profiles.filter { $0.kind == .remoteConfigured }
            if profiles.contains(where: { $0.id == saved.selectedID }) { selectedID = saved.selectedID }
        }
    }
    var selected: GenerationServerProfile { profiles.first { $0.id == selectedID } ?? .embedded }
    func connection(using model: NativModel) -> GenerationConnection? {
        if selected.kind == .localEmbedded { return model.generationConnection() }
        guard let baseURL = selected.baseURL, let key = try? keychain(selected.id).load(), !key.isEmpty else { return nil }
        return .init(baseURL: baseURL, apiKey: key, allowPrivateHTTP: selected.allowPrivateHTTP)
    }
    func select(_ id: String) throws {
        guard profiles.contains(where: { $0.id == id }) else { return }
        let saved = Saved(profiles: profiles.filter { $0.kind == .remoteConfigured }, selectedID: id)
        try GenerationPersistence.write(saved, to: url); selectedID = id
        GenerationPlaybackCoordinator.shared.pause()
    }
    func add(name: String, url: String, apiKey: String, allowPrivateHTTP: Bool) throws {
        let profile = try GenerationServerProfile.remote(name: name, url: url, allowPrivateHTTP: allowPrivateHTTP)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GenerationAPIError(code: "api_key_required", message: "Enter this Nativ server's API key.") }
        try keychain(profile.id).save(apiKey)
        let updated = profiles + [profile]
        try GenerationPersistence.write(Saved(profiles: updated.filter { $0.kind == .remoteConfigured }, selectedID: profile.id), to: self.url)
        profiles = updated; selectedID = profile.id; GenerationPlaybackCoordinator.shared.pause()
    }
    private func keychain(_ id: String) -> ServerAPIKeychain { .init(service: NativBuildIdentity.identifier("generation-server"), account: id) }
    private struct Saved: Codable { let profiles: [GenerationServerProfile]; let selectedID: String }
}
