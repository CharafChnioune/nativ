import Foundation
import NativServerKit
import XCTest

private final class GenerationClientFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var headers = ["Content-Type": "application/json"]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value = Self.lock.withLock { Self.requests.append(request); return (Self.status, Self.body, Self.headers) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: value.0, httpVersion: nil, headerFields: value.2)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GenerationClientTests: XCTestCase {
    private func client(store: String? = "store", url: String = "https://example.invalid") -> NativMusicClient {
        GenerationClientFixture.lock.withLock { GenerationClientFixture.requests = []; GenerationClientFixture.status = 200; GenerationClientFixture.headers = ["Content-Type": "application/json"]; GenerationClientFixture.body = Data(#"{"store_id":"store","contract_version":1,"modality":"music","limits":{}}"#.utf8) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GenerationClientFixture.self]
        return .init(connection: .init(baseURL: URL(string: url)!, apiKey: "test-credential", storeID: store), session: .init(configuration: configuration))
    }
    func testDiscoverySendsBearerAndBindsStoreWithoutMutation() async throws {
        let client = client(); let info = try await client.info()
        XCTAssertEqual(info.storeID, "store")
        let request = try XCTUnwrap(GenerationClientFixture.lock.withLock { GenerationClientFixture.requests.first })
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-credential")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Nativ-Store-ID"), "store")
    }
    func testMutationRequiresStoreAndIdempotencyBeforeNetwork() async throws {
        let client = client(store: nil)
        do { _ = try await client.submit(["prompt": .string("test")], idempotencyKey: "saved"); XCTFail("Unbound mutation") }
        catch let error as GenerationAPIError { XCTAssertEqual(error.code, "store_required") }
        XCTAssertTrue(GenerationClientFixture.lock.withLock { GenerationClientFixture.requests.isEmpty })
        do { _ = try await client.submit([:], idempotencyKey: ""); XCTFail("Missing key") }
        catch let error as GenerationAPIError { XCTAssertEqual(error.code, "missing_idempotency_key") }
    }
    func testReplacementStoreAndUnknownContractAreRejected() async throws {
        let changed = client(store: "old")
        do { _ = try await changed.info(); XCTFail("Changed store") }
        catch let error as GenerationAPIError { XCTAssertEqual(error.code, "store_mismatch") }
        let unsupported = client()
        GenerationClientFixture.lock.withLock { GenerationClientFixture.body = Data(#"{"store_id":"store","contract_version":2,"modality":"music","limits":{}}"#.utf8) }
        do { _ = try await unsupported.info(); XCTFail("Unknown version") }
        catch let error as GenerationAPIError { XCTAssertEqual(error.code, "unsupported_contract") }
    }
    func testNoCredentialOverPlaintextRemoteAndNoPathTraversal() async throws {
        let insecure = client(url: "http://remote.example")
        do { _ = try await insecure.info(); XCTFail("Plaintext remote") }
        catch let error as GenerationAPIError { XCTAssertEqual(error.code, "invalid_server") }
        let secure = client()
        do { _ = try await secure.job(id: "../secrets"); XCTFail("Traversal") }
        catch let error as GenerationAPIError { XCTAssertEqual(error.code, "invalid_identifier") }
        XCTAssertTrue(GenerationClientFixture.lock.withLock { GenerationClientFixture.requests.isEmpty })
    }
    func testSafeStructuredErrorsAndSubmissionIdentityHeader() async throws {
        let client = client()
        GenerationClientFixture.lock.withLock {
            GenerationClientFixture.status = 409
            GenerationClientFixture.body = Data(#"{"error":{"code":"idempotency_conflict","message":"Different parameters","retryable":false}}"#.utf8)
        }
        do { _ = try await client.submit(["model": .string("chosen"), "prompt": .string("test")], idempotencyKey: "stable-key"); XCTFail("Conflict") }
        catch let error as GenerationAPIError { XCTAssertEqual(error.code, "idempotency_conflict") }
        XCTAssertEqual(GenerationClientFixture.lock.withLock { GenerationClientFixture.requests.first?.value(forHTTPHeaderField: "Idempotency-Key") }, "stable-key")
    }
    func testLargeMusicSeedRoundTripsWithoutFloatingPointLoss() throws {
        let bytes = Data(#"{"seed":9007199254740993}"#.utf8)
        let value = try JSONDecoder().decode([String: GenerationJSONValue].self, from: bytes)
        XCTAssertEqual(value["seed"]?.integerValue, 9_007_199_254_740_993)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), String(decoding: bytes, as: UTF8.self))
    }

    func testReferenceUploadBoundsDeclaredAndStreamingResponseAndKeepsIdentity() async throws {
        _ = client() // Reset the shared fixture, including response headers.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationClientFixture.self]
        let client = NativVideoClient(connection: .init(baseURL: URL(string: "https://example.invalid")!, apiKey: "test-credential", storeID: "store"), session: .init(configuration: configuration))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("reference bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for declaredLength in [false, true] {
            GenerationClientFixture.lock.withLock {
                GenerationClientFixture.headers = ["Content-Type": "application/json"]
                if declaredLength { GenerationClientFixture.headers["Content-Length"] = String(16 * 1_024 * 1_024 + 1) }
                GenerationClientFixture.body = declaredLength ? Data("{}".utf8) : Data(repeating: 32, count: 16 * 1_024 * 1_024 + 1)
            }
            do { _ = try await client.uploadInput(file: file); XCTFail("Unbounded upload response") }
            catch let error as GenerationAPIError { XCTAssertEqual(error.code, "response_too_large") }
        }
        GenerationClientFixture.lock.withLock {
            GenerationClientFixture.headers = ["Content-Type": "application/json"]
            GenerationClientFixture.body = Data(#"{"input_id":"input","store_id":"store"}"#.utf8)
        }
        let input = try await client.uploadInput(file: file)
        XCTAssertEqual(input["input_id"]?.stringValue, "input")
        let request = try XCTUnwrap(GenerationClientFixture.lock.withLock { GenerationClientFixture.requests.last })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-credential")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Nativ-Store-ID"), "store")
    }

}
