import Foundation

/// Opt-in transport policy for local speech. Credentials and input cannot follow an off-origin redirect.
public enum NativLoopbackEndpoint {
    /// Local speech must bypass configured system proxies and persistent response/cookie storage.
    static func configure(_ configuration: URLSessionConfiguration) {
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    }
    public static func validate(_ url: URL) throws {
        guard url.scheme == "http", let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw Failure.nonLocalEndpoint
        }
    }
    public static func allowsRedirect(from original: URL, to destination: URL) -> Bool {
        guard (try? validate(original)) != nil, (try? validate(destination)) != nil else { return false }
        return original.scheme == destination.scheme && original.host == destination.host && original.port == destination.port
    }
    public enum Failure: LocalizedError {
        case nonLocalEndpoint
        public var errorDescription: String? { "Live translation requires the local loopback runtime. Remote inference endpoints are not allowed." }
    }
}

final class NativLocalOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let destination = request.url,
              NativLoopbackEndpoint.allowsRedirect(from: original, to: destination) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
