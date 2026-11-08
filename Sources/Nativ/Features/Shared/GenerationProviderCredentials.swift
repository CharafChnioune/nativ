import Foundation

protocol GenerationCredentialStoring {
    func load(profileID: String) throws -> String?
    func save(_ value: String?, profileID: String) throws
}

struct GenerationProviderCredentials: GenerationCredentialStoring {
    static let profileIDs = ["minimax-music3-remote-gpu", "minimax-music3-cloud", "lyria-3.5-hosted", "stable-audio-3-cloud", "ltx-2-5-fast-cloud", "ltx-2-5-pro-cloud", "ltx-2-3-fast-cloud", "ltx-2-3-pro-cloud", "runway-gen4.5"]
    func load(profileID: String) throws -> String? { try keychain(profileID).load() }
    func save(_ value: String?, profileID: String) throws { try keychain(profileID).save(value) }
    private func keychain(_ id: String) -> ServerAPIKeychain {
        .init(service: NativBuildIdentity.identifier("generation-provider"), account: id)
    }
    static func environmentName(_ profileID: String) -> String {
        "NATIV_GENERATION_" + profileID.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() + "_API_KEY"
    }
    static func launchEnvironment(store: GenerationCredentialStoring = Self()) -> [String: String] {
        var environment: [String: String] = [:]
        for id in profileIDs {
            if let key = try? store.load(profileID: id), !key.isEmpty { environment[environmentName(id)] = key }
        }
        return environment
    }
}
