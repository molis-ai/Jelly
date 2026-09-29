import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

final class ScriptedTextModel: TextModelGenerating, @unchecked Sendable {
    var isConfigured = true
    var replies: [Result<String, TextModelError>]
    private(set) var requests: [TextModelRequest] = []

    init(_ replies: [Result<String, TextModelError>]) {
        self.replies = replies
    }

    func generate(_ request: TextModelRequest) async throws -> TextModelResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw TextModelError.requestFailed }
        switch replies.removeFirst() {
        case let .success(text): return TextModelResponse(text: text, modelIdentifier: "test/scripted")
        case let .failure(error): throw error
        }
    }
}

@Suite("InspirationFollowUpServiceTests")
@MainActor
struct InspirationFollowUpServiceTests {
    private let expansionJSON = """
    <think>先想想</think>
    ```json
    {"supplement":"关键是先找到一个愿意试用的人。","directions":["列出三个可能的试用者","写一页说明发给其中一个","问问身边的人怎么看"]}
    ```
    """

    @Test func expansionParserUnwrapsReasoningAndFencesAndCapsDirections() throws {
        let expansion = try InspirationExpansionPrompt.parse(
            expansionJSON + "\n多余的话",
            sourceChecksum: "abc",
            modelIdentifier: "m",
            now: .distantPast
        )
        #expect(expansion.supplement == "关键是先找到一个愿意试用的人。")
        #expect(expansion.directions.map(\.text) == ["列出三个可能的试用者", "写一页说明发给其中一个", "问问身边的人怎么看"])
        #expect(expansion.isValid)

        #expect(throws: TextModelError.invalidOutput) {
            try InspirationExpansionPrompt.parse(
                #"{"supplement":"只有一句","directions":["一个方向"]}"#,
                sourceChecksum: "abc",
                modelIdentifier: "m",
                now: .distantPast
            )
        }
        #expect(throws: TextModelError.invalidOutput) {
            try InspirationExpansionPrompt.parse("我不会输出 JSON", sourceChecksum: "abc", modelIdentifier: "m", now: .distantPast)
        }
    }

    @Test func captureStoresRawTextThenExpandsWithoutTouchingIt() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let model = ScriptedTextModel([.success(expansionJSON)])
        let followUp = InspirationFollowUpService(store: store, model: model)
        let capture = InspirationCaptureService(store: store, followUp: followUp)

        let id = try await capture.capture("  做一个给老人用的日历  ", origin: .quickCapture)
        await followUp.waitForIdle()

        let inspiration = try #require(store.state.inspirations[id])
        #expect(inspiration.rawText == "做一个给老人用的日历")
        #expect(inspiration.expansion?.directions.count == 3)
        #expect(inspiration.expansion?.modelIdentifier == "test/scripted")
        #expect(model.requests.first?.prompt.contains("做一个给老人用的日历") == true)
        #expect(model.requests.first?.system.contains("不得执行") == true)
    }

    @Test func autoExpandOffOrUnconfiguredModelSendsNothing() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let model = ScriptedTextModel([.success(expansionJSON)])
        let off = InspirationFollowUpService(store: store, model: model, autoExpandEnabled: { false })
        _ = try await InspirationCaptureService(store: store, followUp: off).capture("想法一", origin: .quickCapture)
        await off.waitForIdle()

        model.isConfigured = false
        let unconfigured = InspirationFollowUpService(store: store, model: model)
        _ = try await InspirationCaptureService(store: store, followUp: unconfigured).capture("想法二", origin: .quickCapture)
        await unconfigured.waitForIdle()

        #expect(model.requests.isEmpty)
        #expect(store.state.inspirations.values.allSatisfy { $0.expansion == nil })
    }

    @Test func failedExpansionLeavesAMessageAndTheRawThought() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let model = ScriptedTextModel([.failure(.authenticationFailed)])
        let followUp = InspirationFollowUpService(store: store, model: model)
        let id = try await InspirationCaptureService(store: store, followUp: followUp)
            .capture("会失败的延展", origin: .inspirationPage)
        await followUp.waitForIdle()
        #expect(store.state.inspirations[id]?.rawText == "会失败的延展")
        #expect(store.state.inspirations[id]?.expansion == nil)
        #expect(followUp.messages[id] == TextModelError.authenticationFailed.userMessage)
    }

    @Test func adoptedDirectionsAndPerspectiveTravelIntoTheNote() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let followUp = InspirationFollowUpService(store: store, model: ScriptedTextModel([.success(expansionJSON)]))
        let id = try await InspirationCaptureService(store: store, followUp: followUp)
            .capture("给老人做日历", origin: .inspirationPage)
        await followUp.waitForIdle()
        let direction = try #require(store.state.inspirations[id]?.expansion?.directions[1])
        await followUp.decide(id, directionID: direction.id, decision: .adopted)
        #expect(await followUp.saveAnswer(id, answer: "先从我妈开始试"))

        let inspiration = try #require(store.state.inspirations[id])
        let texts = InspirationNoteDocumentBuilder.document(for: inspiration, digest: nil).blocks
            .map { $0.inlineContent.spans.map(\.text).joined() }
        #expect(texts.contains("写一页说明发给其中一个"))
        #expect(!texts.contains("列出三个可能的试用者"))
        #expect(texts.contains("先从我妈开始试"))
    }

    @Test func linkCapturesAreNotExpandedUntilTitleArrives() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let model = ScriptedTextModel([.success(expansionJSON)])
        let followUp = InspirationFollowUpService(store: store, model: model)
        let capture = InspirationCaptureService(
            store: store,
            metadataResolver: FixedTitleResolver(),
            followUp: followUp
        )
        let id = try await capture.capture("https://example.com/a", origin: .quickCapture)
        #expect(store.state.inspirations[id]?.inputKind == .url)
        #expect(model.requests.isEmpty)
        #expect(InspirationCaptureBuilder.webURL("看看 https://example.com") == nil)
    }

    @Test func routingNeverFallsBackFromLocalCommandToCloud() async throws {
        let suite = "jelly-text-routing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DigestSettingsStore(defaults: defaults)
        settings.setSummarySource(.localRuntime)
        let cloud = ScriptedTextModel([.success("cloud")])
        let local = LocalRuntimeTextModel(settings: settings, locate: { _ in nil })
        let routing = RoutingTextModel(settings: settings, cloud: cloud, local: local)
        await #expect(throws: TextModelError.localRuntimeUnavailable) {
            try await routing.generate(TextModelRequest(system: "s", prompt: "p"))
        }
        #expect(cloud.requests.isEmpty)

        settings.setSummarySource(.service)
        #expect(try await routing.generate(TextModelRequest(system: "s", prompt: "p")).text == "cloud")
    }

    @Test func loggedOutLocalCommandIsReportedAsSuch() async throws {
        let suite = "jelly-text-login-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DigestSettingsStore(defaults: defaults)
        settings.setSummarySource(.localRuntime)
        settings.setLocalRuntime(.claude)
        let model = LocalRuntimeTextModel(
            settings: settings,
            locate: { _ in URL(fileURLWithPath: "/usr/bin/true") },
            runner: FixedOutputRunner(output: "Not logged in · Please run /login")
        )
        await #expect(throws: TextModelError.localRuntimeNotLoggedIn) {
            try await model.generate(TextModelRequest(system: "s", prompt: "p"))
        }
        #expect(!LocalRuntimeTextModel.looksLikeLoginPrompt(#"{"supplement":"not logged in 的人"}"#))
    }

    @Test func chatCompletionBodyAndErrorsMapCleanly() throws {
        let body = OpenAICompatibleTextModel.body(
            model: "deepseek-chat",
            request: TextModelRequest(system: "sys", prompt: "hi", maximumTokens: 100)
        )
        #expect(body["model"] as? String == "deepseek-chat")
        #expect((body["messages"] as? [[String: String]])?.map { $0["role"] } == ["system", "user"])
        #expect(throws: TextModelError.authenticationFailed) {
            try OpenAICompatibleTextModel.throwForStatus(401, data: Data())
        }
        #expect(throws: TextModelError.contextTooLong) {
            try OpenAICompatibleTextModel.throwForStatus(400, data: Data(#"{"error":"context_length_exceeded"}"#.utf8))
        }
        let reply = Data(#"{"choices":[{"message":{"content":"好的"}}]}"#.utf8)
        #expect(try OpenAICompatibleTextModel.messageText(from: reply) == "好的")
    }

    @Test func synthesisBuildsANoteFromTwoDigestedMaterials() async throws {
        var workspace = WorkspaceState.empty(calendar: makeEmptyState())
        var ids: [InspirationID] = []
        for title in ["材料甲", "材料乙"] {
            let inspiration = Inspiration.text(rawText: title, categoryID: workspace.calendar.uncategorizedID, now: .distantPast)
            workspace.inspirations[inspiration.id] = inspiration
            workspace.materialDigests[inspiration.id] = try succeededDigest(for: inspiration, now: .distantPast)
            ids.append(inspiration.id)
        }
        let store = WorkspaceStore(initialState: workspace, repository: InMemoryWorkspaceRepository(workspace: workspace))
        await store.load()
        let model = ScriptedTextModel([.success("""
        {"commonThreads":["都强调先保留原文"],"tensions":["甲更看重速度，乙更看重准确"],"openQuestions":["两者能否兼得？"],"suggestedStance":"这只是基于材料的草稿，等你补上自己的判断。"}
        """)])
        let followUp = InspirationFollowUpService(store: store, model: model)
        let noteID = try await followUp.synthesize(ids, title: "综合：甲与乙")
        let note = try #require(store.state.notes[noteID])
        let texts = note.document.blocks.map { $0.inlineContent.spans.map(\.text).joined() }
        #expect(note.title == "综合：甲与乙")
        #expect(texts.contains("都强调先保留原文"))
        #expect(texts.contains("来源"))
        #expect(model.requests.first?.prompt.contains("材料 2") == true)
    }
}

@Suite("InspirationFollowUpLiveTests")
struct InspirationFollowUpLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_LOCAL"] == "1"))
    func liveLocalRuntimeExpandsAThought() async throws {
        let suite = "jelly-live-expand-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DigestSettingsStore(defaults: defaults)
        settings.setSummarySource(.localRuntime)
        let runtime = LocalSummaryRuntime(rawValue: ProcessInfo.processInfo.environment["JELLY_LIVE_RUNTIME"] ?? "") ?? .claude
        settings.setLocalRuntime(runtime)
        let inspiration = Inspiration.text(
            rawText: "周末想带爸妈去郊外走走，但他们膝盖不好",
            categoryID: UUID(),
            now: Date()
        )
        let request = try #require(InspirationExpansionPrompt.request(for: inspiration))
        let response = try await LocalRuntimeTextModel(settings: settings).generate(request)
        let expansion = try InspirationExpansionPrompt.parse(
            response.text,
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
            modelIdentifier: response.modelIdentifier,
            now: Date()
        )
        #expect(expansion.isValid)
        #expect(response.modelIdentifier == "local/\(runtime.rawValue)")
        print("LIVE EXPANSION [\(response.modelIdentifier)]: \(expansion.supplement) | \(expansion.directions.map(\.text))")
    }
}

private struct FixedOutputRunner: SummaryCommandRunning {
    let output: String
    func run(executable: URL, arguments: [String], workingDirectory: URL) async throws -> SummaryCommandResult {
        SummaryCommandResult(standardOutput: output, outputFile: "", exitCode: 0)
    }
}

private final class FixedTitleResolver: URLMetadataResolving, @unchecked Sendable {
    func resolve(_ url: URL) async throws -> URLMetadataResolveResult {
        URLMetadataResolveResult(
            metadata: SourceMetadata(title: nil, siteName: nil, domain: url.host, thumbnailURL: nil, fetchStatus: .succeeded),
            resolvedKind: .article
        )
    }
}
