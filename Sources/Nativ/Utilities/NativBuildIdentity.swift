import Foundation

/// This fork deliberately does not read or migrate the official application's data.
enum NativBuildIdentity {
    static let namespace = "io.github.charafchnioune.nativ"
    static let repository = "CharafChnioune/nativ"
    static let defaultServerPort = 8181
    static let applicationSupportDirectoryName = namespace
    static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return root.appendingPathComponent(namespace, isDirectory: true)
    }
    static func identifier(_ suffix: String) -> String { namespace + "." + suffix }
}

struct NativUpdateConfiguration: Equatable {
    static let upstreamPublicKey = "A8x4wdNekd1aoWpU8bVdsNdOFzuua8nC1mfLCwGDSPk="
    let stableFeed: URL
    let previewFeed: URL
    let publicKey: String

    init?(info: [String: Any]?) {
        guard info?["CFBundleIdentifier"] as? String == NativBuildIdentity.namespace,
              let stable = info?["SUFeedURL"] as? String,
              let preview = info?["NativPreviewFeedURL"] as? String,
              let key = info?["SUPublicEDKey"] as? String,
              key != Self.upstreamPublicKey, Data(base64Encoded: key)?.count == 32,
              let stableURL = URL(string: stable), let previewURL = URL(string: preview),
              Self.isForkFeed(stableURL, preview: false), Self.isForkFeed(previewURL, preview: true) else {
            return nil
        }
        stableFeed = stableURL
        previewFeed = previewURL
        publicKey = key
    }

    private static func isForkFeed(_ url: URL, preview: Bool) -> Bool {
        let path = "/" + NativBuildIdentity.repository + (preview
            ? "/releases/download/preview/appcast.xml" : "/releases/latest/download/appcast.xml")
        return url.scheme == "https" && url.host == "github.com" && url.path == path
            && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
    }
}
