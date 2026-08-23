import Foundation
@testable import CalendarApp

/// Test-only MiniMax Anthropic Messages client. Keep this out of CalendarApp production sources.
struct MiniMaxLiveConfiguration: Equatable, Sendable {
    var apiKey: String?
    var baseURL: URL
    var model: String

    static let defaultBaseURL = URL(string: "https://api.minimaxi.com/anthropic")!
    static let defaultModel = "MiniMax-M3"

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MiniMaxLiveConfiguration {
        MiniMaxLiveConfiguration(
            apiKey: nonempty(environment["MINIMAX_API_KEY"]),
            baseURL: nonempty(environment["JELLY_MINIMAX_BASE_URL"]).flatMap(URL.init(string:))
                ?? defaultBaseURL,
            model: nonempty(environment["JELLY_MINIMAX_MODEL"]) ?? defaultModel
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

protocol MiniMaxMessagesTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct MiniMaxLiveURLSessionTransport: MiniMaxMessagesTransport {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: makeSessionConfiguration())) {
        self.session = session
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return configuration
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxLiveError.invalidJSON
        }
        return (data, http)
    }
}

struct MiniMaxLiveClient: Sendable {
    var configuration: MiniMaxLiveConfiguration
    var transport: any MiniMaxMessagesTransport

    func text(system: String, prompt: String) async throws -> String {
        guard let apiKey = configuration.apiKey, !apiKey.isEmpty else {
            throw MiniMaxLiveError.missingAPIKey
        }
        var request = URLRequest(url: configuration.baseURL.appending(path: "v1/messages"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            MessagesRequestBody(
                model: configuration.model,
                maxTokens: 4096,
                system: system,
                messages: [MessagesRequestBody.Message(role: "user", content: prompt)]
            )
        )
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw MiniMaxLiveError.transportFailure
        }
        guard (200...299).contains(response.statusCode) else {
            throw MiniMaxLiveError.httpStatus(
                code: response.statusCode,
                message: Self.safeHTTPMessage(body: data, apiKey: apiKey)
            )
        }
        return try Self.extractText(from: data)
    }

    private static func extractText(from data: Data) throws -> String {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MiniMaxLiveError.invalidJSON
        }
        guard let dictionary = object as? [String: Any] else {
            throw MiniMaxLiveError.invalidJSON
        }
        guard let content = dictionary["content"] as? [[String: Any]] else {
            throw MiniMaxLiveError.missingTextBlock
        }
        let texts: [String] = content.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String ?? ""
        }
        guard !texts.isEmpty else {
            throw MiniMaxLiveError.missingTextBlock
        }
        return texts.joined()
    }

    private static func safeHTTPMessage(body: Data, apiKey: String) -> String {
        var message = "request failed"
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let parts = [error["type"] as? String, error["message"] as? String]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !parts.isEmpty {
                message = parts.joined(separator: ": ")
            }
        } else {
            let raw = String(decoding: body, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                message = raw
            }
        }
        return String(redact(message, secret: apiKey).prefix(300))
    }

    private static func redact(_ text: String, secret: String) -> String {
        text.replacingOccurrences(of: secret, with: "<redacted>")
    }
}

enum MiniMaxResponseDecoder {
    static func decodeClarification(_ text: String) throws -> ClarificationPayload {
        do {
            return try JSONDecoder().decode(
                ClarificationPayload.self,
                from: Data(unwrapJSONText(text).utf8)
            )
        } catch {
            throw MiniMaxLiveError.invalidJSON
        }
    }

    static func decodeActions(_ text: String) throws -> [PlannerCandidate] {
        let payload: ActionListPayload
        do {
            payload = try JSONDecoder().decode(
                ActionListPayload.self,
                from: Data(unwrapJSONText(text).utf8)
            )
        } catch {
            throw MiniMaxLiveError.invalidJSON
        }
        return try payload.actions.map { action in
            let existingID: UUID?
            if let raw = action.existingID {
                guard let uuid = UUID(uuidString: raw) else {
                    throw MiniMaxLiveError.invalidExistingID(raw)
                }
                existingID = uuid
            } else {
                existingID = nil
            }
            return PlannerCandidate(
                existingID: existingID,
                title: action.title,
                completionDescription: action.completionDescription,
                estimatedMinutes: action.estimatedMinutes
            )
        }
    }

    private static func unwrapJSONText(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = "```json\n"
        let closing = "```"
        guard text.hasPrefix(opening),
              text.hasSuffix(closing),
              text.count >= opening.count + closing.count
        else {
            return text
        }
        let innerStart = text.index(text.startIndex, offsetBy: opening.count)
        let innerEnd = text.index(text.endIndex, offsetBy: -closing.count)
        return String(text[innerStart..<innerEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ClarificationPayload: Decodable, Equatable, Sendable {
    let needsFollowUp: Bool
    let question: String
    let quickAnswers: [String]
}

enum MiniMaxLiveError: Error, Equatable, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    case missingAPIKey
    case httpStatus(code: Int, message: String)
    case missingTextBlock
    case invalidJSON
    case invalidExistingID(String)
    case transportFailure

    var description: String { safeDescription }
    var debugDescription: String { safeDescription }
    var errorDescription: String? { safeDescription }

    private var safeDescription: String {
        switch self {
        case .missingAPIKey:
            return "MiniMax API key is missing."
        case .httpStatus(let code, let message):
            return "MiniMax HTTP \(code): \(message)"
        case .missingTextBlock:
            return "MiniMax response did not contain a text block."
        case .invalidJSON:
            return "MiniMax response was not valid JSON."
        case .invalidExistingID:
            return "MiniMax action existingID is not a valid UUID."
        case .transportFailure:
            return "MiniMax transport failed."
        }
    }
}

extension MiniMaxLiveError: CustomNSError {
    static var errorDomain: String { "MiniMaxLiveError" }

    var errorCode: Int {
        switch self {
        case .missingAPIKey: return 1
        case .httpStatus(let code, _): return code
        case .missingTextBlock: return 2
        case .invalidJSON: return 3
        case .invalidExistingID: return 4
        case .transportFailure: return 5
        }
    }

    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: description]
    }
}

private struct ActionListPayload: Decodable {
    let actions: [ActionPayload]
}

private struct ActionPayload: Decodable {
    let existingID: String?
    let title: String
    let completionDescription: String
    let estimatedMinutes: Int
}

private struct MessagesRequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}
