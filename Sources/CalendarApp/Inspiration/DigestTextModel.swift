import Foundation

/// One prompt in, one reply out, using whatever the user picked in 摘要设置:
/// a cloud preset with a Keychain key, or a logged-in Codex / Claude command
/// on this Mac. Inspiration expansion, decomposition and synthesis all go
/// through here so there is exactly one place that decides where text is sent.
struct TextModelRequest: Equatable, Sendable {
    var system: String
    var prompt: String
    var maximumTokens: Int = 1_200
    var temperature: Double = 0.4
}

struct TextModelResponse: Equatable, Sendable {
    var text: String
    /// "host/model" for cloud services, "local/codex" for commands.
    var modelIdentifier: String
}

enum TextModelError: Error, Equatable, Sendable {
    case notConfigured
    case localRuntimeUnavailable
    case localRuntimeNotLoggedIn
    case authenticationFailed
    case accessDenied
    case requestFailed
    case contextTooLong
    case invalidOutput

    var userMessage: String {
        switch self {
        case .notConfigured: "还没有在设置 › 摘要里选好模型。"
        case .localRuntimeUnavailable: "这台 Mac 上找不到所选的本机命令，没有改用云端。"
        case .localRuntimeNotLoggedIn: "本机命令还没有登录，请先在终端里登录它；没有改用云端。"
        case .authenticationFailed: "模型服务拒绝了密钥，请在设置里更新。"
        case .accessDenied: "模型服务拒绝了这次请求。"
        case .requestFailed: "模型暂时没有回应，稍后再试。"
        case .contextTooLong: "内容太长，模型放不下。"
        case .invalidOutput: "模型的回答格式不对，没有保存。"
        }
    }
}

protocol TextModelGenerating: Sendable {
    var isConfigured: Bool { get }
    func generate(_ request: TextModelRequest) async throws -> TextModelResponse
}

final class OpenAICompatibleTextModel: TextModelGenerating, @unchecked Sendable {
    private static let maximumResponseBytes = 1_000_000
    private let settings: DigestSettingsStore
    private let credentials: any DigestCredentialStoring
    private let session: URLSession

    init(
        settings: DigestSettingsStore,
        credentials: any DigestCredentialStoring,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.settings = settings
        self.credentials = credentials
        session = URLSession(
            configuration: OpenAICompatibleMaterialSummarizer.makeSessionConfiguration(from: configuration)
        )
    }

    var isConfigured: Bool {
        DigestRuntimeConfiguration.isConfigured(
            endpoint: settings.endpoint,
            model: settings.model,
            secret: try? credentials.load()
        )
    }

    func generate(_ request: TextModelRequest) async throws -> TextModelResponse {
        guard let endpoint = DigestSettingsNormalization.endpoint(settings.endpoint),
              let model = DigestSettingsNormalization.model(settings.model),
              let secret = try? credentials.load(),
              !secret.isEmpty,
              let endpointURL = URL(string: endpoint),
              let host = endpointURL.host
        else {
            throw TextModelError.notConfigured
        }
        var urlRequest = URLRequest(
            url: endpointURL
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("completions", isDirectory: false)
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: Self.body(model: model, request: request),
            options: [.sortedKeys]
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TextModelError.requestFailed
        }
        guard data.count <= Self.maximumResponseBytes,
              let http = response as? HTTPURLResponse
        else {
            throw TextModelError.requestFailed
        }
        try Self.throwForStatus(http.statusCode, data: data)
        let text = try Self.messageText(from: data)
        return TextModelResponse(text: text, modelIdentifier: "\(host)/\(model)")
    }

    static func body(model: String, request: TextModelRequest) -> [String: Any] {
        [
            "model": model,
            "temperature": request.temperature,
            "max_tokens": request.maximumTokens,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.prompt]
            ]
        ]
    }

    static func throwForStatus(_ status: Int, data: Data) throws {
        if (200..<300).contains(status) { return }
        if status == 401 { throw TextModelError.authenticationFailed }
        if status == 403 { throw TextModelError.accessDenied }
        let text = String(decoding: data, as: UTF8.self).lowercased()
        if status == 413 || text.contains("context_length") || text.contains("context length") {
            throw TextModelError.contextTooLong
        }
        throw TextModelError.requestFailed
    }

    static func messageText(from data: Data) throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let choices = object?["choices"] as? [[String: Any]]
        guard let message = choices?.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TextModelError.invalidOutput
        }
        return content
    }
}

final class LocalRuntimeTextModel: TextModelGenerating, @unchecked Sendable {
    private let settings: DigestSettingsStore
    private let locate: @Sendable (LocalSummaryRuntime) -> URL?
    private let runner: any SummaryCommandRunning

    init(
        settings: DigestSettingsStore,
        locate: @escaping @Sendable (LocalSummaryRuntime) -> URL? = { LocalRuntimeLocator.find($0) },
        runner: any SummaryCommandRunning = LiveSummaryCommandRunner()
    ) {
        self.settings = settings
        self.locate = locate
        self.runner = runner
    }

    var isConfigured: Bool {
        settings.summarySource == .localRuntime
    }

    func generate(_ request: TextModelRequest) async throws -> TextModelResponse {
        guard settings.summarySource == .localRuntime else { throw TextModelError.notConfigured }
        let runtime = settings.localRuntime
        guard let executable = locate(runtime) else { throw TextModelError.localRuntimeUnavailable }
        let prompt = request.system + "\n\n" + request.prompt
        guard prompt.utf8.count <= 180_000 else { throw TextModelError.contextTooLong }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result: SummaryCommandResult
        do {
            result = try await runner.run(
                executable: executable,
                arguments: LocalRuntimeMaterialSummarizer.arguments(
                    runtime: runtime,
                    prompt: prompt,
                    directory: directory,
                    outputFile: directory.appendingPathComponent("last-message.txt")
                ),
                workingDirectory: directory
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TextModelError.requestFailed
        }
        let text = result.outputFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.standardOutput
            : result.outputFile
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw result.exitCode == 0 ? TextModelError.invalidOutput : TextModelError.requestFailed
        }
        if Self.looksLikeLoginPrompt(text) {
            throw TextModelError.localRuntimeNotLoggedIn
        }
        return TextModelResponse(text: text, modelIdentifier: "local/\(runtime.rawValue)")
    }

    /// `claude -p` prints "Not logged in · Please run /login" and exits 0.
    static func looksLikeLoginPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count < 300, !trimmed.contains("{") else { return false }
        return trimmed.contains("not logged in") || trimmed.contains("please run /login")
            || trimmed.contains("codex login")
    }
}

final class RoutingTextModel: TextModelGenerating, @unchecked Sendable {
    private let settings: DigestSettingsStore
    private let cloud: any TextModelGenerating
    private let local: any TextModelGenerating

    init(settings: DigestSettingsStore, cloud: any TextModelGenerating, local: any TextModelGenerating) {
        self.settings = settings
        self.cloud = cloud
        self.local = local
    }

    convenience init(settings: DigestSettingsStore, credentials: any DigestCredentialStoring) {
        self.init(
            settings: settings,
            cloud: OpenAICompatibleTextModel(settings: settings, credentials: credentials),
            local: LocalRuntimeTextModel(settings: settings)
        )
    }

    var isConfigured: Bool {
        settings.summarySource == .localRuntime ? local.isConfigured : cloud.isConfigured
    }

    func generate(_ request: TextModelRequest) async throws -> TextModelResponse {
        // Never fall back from a local command to the cloud: the user chose
        // where their text goes.
        settings.summarySource == .localRuntime
            ? try await local.generate(request)
            : try await cloud.generate(request)
    }
}

/// Lenient JSON extraction for chatty models: drops `<think>` blocks and code
/// fences, then takes the outermost object.
enum TextModelJSON {
    static func object(from raw: String) throws -> [String: Any] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let closing = text.range(of: "</think>") {
            text = String(text[closing.upperBound...])
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end
        else {
            throw TextModelError.invalidOutput
        }
        let candidate = String(text[start...end])
        guard let data = candidate.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw TextModelError.invalidOutput
        }
        return object
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { element in
            let text = (element as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
    }
}
