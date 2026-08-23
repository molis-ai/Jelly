import Foundation
import Testing
@testable import CalendarApp

@Suite("MiniMaxDecompositionLiveSupportTests")
struct MiniMaxDecompositionLiveSupportTests {
    @Test func decoderAcceptsPlainAndFencedClarificationJSON() throws {
        let plain = #"{"needsFollowUp":true,"question":"最晚什么时候完成？","quickAnswers":["本周","下周"]}"#
        let fenced = "```json\n\(plain)\n```"
        #expect(try MiniMaxResponseDecoder.decodeClarification(plain).needsFollowUp)
        #expect(try MiniMaxResponseDecoder.decodeClarification(fenced).quickAnswers.count == 2)
    }

    @Test func decoderMapsActionsToProductionPlannerCandidates() throws {
        let identifiedID = "00000000-0000-0000-0000-000000000701"
        let text = """
        {"actions":[\
        {"existingID":null,"title":"联系诊所","completionDescription":"拿到可预约时间","estimatedMinutes":15},\
        {"existingID":"\(identifiedID)","title":"记录确认","completionDescription":"把短信写进笔记","estimatedMinutes":20}\
        ]}
        """
        let actions = try MiniMaxResponseDecoder.decodeActions(text)
        #expect(actions[0].title == "联系诊所")
        #expect(actions[0].existingID == nil)
        #expect(actions[0].completionDescription == "拿到可预约时间")
        #expect(actions[0].estimatedMinutes == 15)
        #expect(actions[1].existingID == UUID(uuidString: identifiedID))
        #expect(actions[1].title == "记录确认")
        #expect(actions[1].estimatedMinutes == 20)
    }

    @Test func decoderRejectsInvalidExistingIDWithoutCoercing() {
        let text = #"{"actions":[{"existingID":"not-a-uuid","title":"联系诊所","completionDescription":"拿到可预约时间","estimatedMinutes":15}]}"#
        #expect(throws: MiniMaxLiveError.invalidExistingID("not-a-uuid")) {
            try MiniMaxResponseDecoder.decodeActions(text)
        }
    }

    @Test func decoderRejectsNonJSONBodies() {
        #expect(throws: MiniMaxLiveError.invalidJSON) {
            try MiniMaxResponseDecoder.decodeClarification("this is not json")
        }
        #expect(throws: MiniMaxLiveError.invalidJSON) {
            try MiniMaxResponseDecoder.decodeActions("```json\nnot-json\n```")
        }
    }

    @Test func decoderRejectsNonJSONFenceAndUnterminatedJSONFence() {
        let plain = #"{"needsFollowUp":true,"question":"最晚什么时候完成？","quickAnswers":["本周","下周"]}"#
        #expect(throws: MiniMaxLiveError.invalidJSON) {
            try MiniMaxResponseDecoder.decodeClarification("```swift\n\(plain)\n```")
        }
        #expect(throws: MiniMaxLiveError.invalidJSON) {
            try MiniMaxResponseDecoder.decodeClarification("```json\n\(plain)")
        }
    }

    @Test func configurationReadsOnlyDeclaredEnvironmentKeysAndDefaults() {
        let empty = MiniMaxLiveConfiguration.fromEnvironment([:])
        #expect(empty.apiKey == nil)
        #expect(empty.baseURL.absoluteString == "https://api.minimaxi.com/anthropic")
        #expect(empty.model == "MiniMax-M3")

        let custom = MiniMaxLiveConfiguration.fromEnvironment([
            "MINIMAX_API_KEY": "jelly-test-fake-minimax-token",
            "JELLY_MINIMAX_BASE_URL": "https://minimax.test/anthropic",
            "JELLY_MINIMAX_MODEL": "MiniMax-Test",
            "OTHER_SECRET": "must-be-ignored",
            "JELLY_MINIMAX_LIVE": "1"
        ])
        #expect(custom.apiKey == "jelly-test-fake-minimax-token")
        #expect(custom.baseURL.absoluteString == "https://minimax.test/anthropic")
        #expect(custom.model == "MiniMax-Test")
    }

    @Test func clientPostsSystemAndPromptSeparatelyToMessagesEndpoint() async throws {
        let fakeKey = "jelly-test-fake-minimax-token"
        let transport = ScriptedMiniMaxTransport(
            body: messagesEnvelope(texts: [#"{"ok":true}"#])
        )
        let client = MiniMaxLiveClient(
            configuration: MiniMaxLiveConfiguration(
                apiKey: fakeKey,
                baseURL: URL(string: "https://minimax.test/anthropic")!,
                model: "MiniMax-M3"
            ),
            transport: transport
        )

        _ = try await client.text(system: "system-instructions", prompt: "user-prompt")

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://minimax.test/anthropic/v1/messages")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)")

        let payload = try #require(request.httpBody)
        let body = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect(body?["model"] as? String == "MiniMax-M3")
        #expect(body?["system"] as? String == "system-instructions")
        let messages = body?["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] as? String == "user")
        #expect(messages?.first?["content"] as? String == "user-prompt")
        #expect(messages?.first?["content"] as? String != "system-instructions")
    }

    @Test func clientMergesAllTextBlocksOn2xx() async throws {
        let transport = ScriptedMiniMaxTransport(
            body: messagesEnvelope(
                texts: ["{\"needsFollowUp\":true,", "\"question\":\"x\",\"quickAnswers\":[]}"],
                        extraBlocks: [["type": "tool_use", "id": "1", "name": "noop"]]
            )
        )
        let client = makeClient(transport: transport)

        let text = try await client.text(system: "s", prompt: "p")
        #expect(text == #"{"needsFollowUp":true,"question":"x","quickAnswers":[]}"#)
    }

    @Test func clientRejectsMissingTextBlock() async {
        let transport = ScriptedMiniMaxTransport(
            body: messagesEnvelope(texts: [], extraBlocks: [["type": "tool_use", "id": "1"]])
        )
        let client = makeClient(transport: transport)
        await #expect(throws: MiniMaxLiveError.missingTextBlock) {
            try await client.text(system: "s", prompt: "p")
        }
    }

    @Test func clientRejectsNonJSONEnvelope() async {
        let transport = ScriptedMiniMaxTransport(body: Data("not-json".utf8))
        let client = makeClient(transport: transport)
        await #expect(throws: MiniMaxLiveError.invalidJSON) {
            try await client.text(system: "s", prompt: "p")
        }
    }

    @Test func clientReturnsNon2xxStatusWithoutLeakingAuthorization() async {
        let fakeKey = "jelly-test-fake-minimax-token"
        let transport = ScriptedMiniMaxTransport(
            statusCode: 401,
            body: Data(#"{"error":{"type":"authentication_error","message":"rejected \#(fakeKey)"}}"#.utf8)
        )
        let client = makeClient(apiKey: fakeKey, transport: transport)

        do {
            _ = try await client.text(system: "s", prompt: "p")
            Issue.record("non-2xx response was accepted")
        } catch let error as MiniMaxLiveError {
            guard case let .httpStatus(code, message) = error else {
                Issue.record("expected httpStatus, got \(error)")
                return
            }
            #expect(code == 401)
            assertNoSecretLeak(error, secret: fakeKey)
            #expect(!message.contains(fakeKey))
        } catch {
            Issue.record("expected MiniMaxLiveError, got \(error)")
        }
    }

    @Test func clientConvertsTransportThrowsToTransportFailureWithoutLeakingSecret() async {
        let fakeKey = "jelly-test-fake-minimax-token"
        let transport = ScriptedMiniMaxTransport(
            body: messagesEnvelope(texts: ["{}"]),
            error: LeakyTransportError(secret: fakeKey)
        )
        let client = makeClient(apiKey: fakeKey, transport: transport)

        do {
            _ = try await client.text(system: "s", prompt: "p")
            Issue.record("throwing transport was accepted")
        } catch let error as MiniMaxLiveError {
            guard case .transportFailure = error else {
                Issue.record("expected transportFailure, got \(error)")
                return
            }
            assertNoSecretLeak(error, secret: fakeKey)
        } catch {
            Issue.record("expected MiniMaxLiveError, got \(error)")
        }
    }

    @Test func clientConvertsMiniMaxLiveErrorThrownByTransportToTransportFailureWithoutLeakingSecret() async {
        let fakeKey = "jelly-test-fake-minimax-token"
        let transport = ScriptedMiniMaxTransport(
            body: Data(),
            error: MiniMaxLiveError.httpStatus(code: 500, message: fakeKey)
        )
        let client = makeClient(apiKey: fakeKey, transport: transport)

        do {
            _ = try await client.text(system: "s", prompt: "p")
            Issue.record("throwing transport was accepted")
        } catch let error as MiniMaxLiveError {
            guard case .transportFailure = error else {
                Issue.record("expected transportFailure, got \(error)")
                return
            }
            assertNoSecretLeak(error, secret: fakeKey)
        } catch {
            Issue.record("expected MiniMaxLiveError, got \(error)")
        }
    }

    @Test func clientDoesNotSendWhenAPIKeyIsMissing() async {
        let transport = ScriptedMiniMaxTransport(body: messagesEnvelope(texts: ["{}"]))
        let client = MiniMaxLiveClient(
            configuration: MiniMaxLiveConfiguration.fromEnvironment([:]),
            transport: transport
        )
        await #expect(throws: MiniMaxLiveError.missingAPIKey) {
            try await client.text(system: "s", prompt: "p")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func liveTransportUsesEphemeralSessionAndTimeouts() {
        let configuration = MiniMaxLiveURLSessionTransport.makeSessionConfiguration()
        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(configuration.timeoutIntervalForResource == 45)
        #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    }

    private func makeClient(
        apiKey: String = "jelly-test-fake-minimax-token",
        transport: ScriptedMiniMaxTransport
    ) -> MiniMaxLiveClient {
        MiniMaxLiveClient(
            configuration: MiniMaxLiveConfiguration(
                apiKey: apiKey,
                baseURL: URL(string: "https://minimax.test/anthropic")!,
                model: "MiniMax-M3"
            ),
            transport: transport
        )
    }
}

private final class ScriptedMiniMaxTransport: MiniMaxMessagesTransport, @unchecked Sendable {
    var statusCode: Int
    var body: Data
    var error: (any Error)?
    private(set) var requests: [URLRequest] = []

    init(statusCode: Int = 200, body: Data, error: (any Error)? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let error {
            throw error
        }
        let url = request.url ?? URL(string: "https://minimax.test/missing")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}

private struct LeakyTransportError: Error, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    let secret: String

    var description: String { "URLSession failed while sending \(secret)" }
    var debugDescription: String { "LeakyTransportError(\(secret))" }
    var errorDescription: String? { description }
}

private func messagesEnvelope(texts: [String], extraBlocks: [[String: Any]] = []) -> Data {
    var content: [[String: Any]] = texts.map { ["type": "text", "text": $0] }
    content.append(contentsOf: extraBlocks)
    return try! JSONSerialization.data(withJSONObject: ["content": content])
}

private func assertNoSecretLeak(_ error: Error, secret: String) {
    var parts = [
        String(describing: error),
        String(reflecting: error),
        error.localizedDescription
    ]
    let nsError = error as NSError
    parts.append(nsError.domain)
    parts.append(String(nsError.code))
    for (key, value) in nsError.userInfo {
        parts.append("\(key)")
        parts.append("\(value)")
    }
    let dump = parts.joined(separator: "\n")
    #expect(!dump.contains(secret), "error description leaked the test token")
}
