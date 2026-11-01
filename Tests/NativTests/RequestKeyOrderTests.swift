import XCTest

@testable import NativServerKit

/// Servers that reuse a prompt prefix match raw text, so one request must always serialise the same way.
final class RequestKeyOrderTests: XCTestCase {
    private let server = URL(string: "http://127.0.0.1:8080")!
    private let keys = (0..<40).map { "field_\($0)" }

    private func tool(keyOrder: [String]) -> MLXChatToolDefinition {
        var properties: [String: MLXJSONValue] = [:]
        for key in keyOrder {
            properties[key] = .object(["type": .string("string"), "description": .string(key)])
        }
        let parameters = MLXJSONValue.object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array([.string(keys[0])]), "additionalProperties": .bool(false),
        ])
        return MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: "lookup", description: "Look something up", parameters: parameters
        ))
    }

    private func body(tools: [MLXChatToolDefinition]) throws -> Data {
        let request = MLXChatCompletionRequest(
            model: "org/model", messages: [MLXChatMessage(role: "user", content: "hi")],
            maxTokens: 64, temperature: 0.6, topK: 20, topP: 0.95, minP: 0, tools: tools
        )
        let wire = try NativResponsesClient(baseURL: server, tenant: "test").makeResponseRequest(
            request, input: try NativResponsesClient.inputItems(request.messages), compactThreshold: 96000
        )
        return try XCTUnwrap(wire.httpBody)
    }

    func testTheSameToolsAreSentAsIdenticalBytesEveryTime() throws {
        var bodies = Set<Data>()
        for attempt in 0..<30 {
            let order = attempt.isMultiple(of: 2) ? keys : keys.shuffled()
            bodies.insert(try body(tools: [tool(keyOrder: order)]))
        }
        XCTAssertEqual(bodies.count, 1, "Equal tool definitions must produce byte-identical request bodies")
    }

    func testToolCallArgumentsDecodedFromAnObjectSerialiseTheSameEveryTime() throws {
        let object = "{" + keys.map { "\"\($0)\": 1" }.joined(separator: ",") + "}"
        var texts = Set<String>()
        for _ in 0..<30 {
            let json = "{\"name\":\"lookup\",\"arguments\":\(object)}"
            let call = try JSONDecoder().decode(MLXChatFunctionCall.self, from: Data(json.utf8))
            texts.insert(try XCTUnwrap(call.arguments))
        }
        XCTAssertEqual(texts.count, 1)
    }
}
