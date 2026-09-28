import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("RoutingMaterialSummarizerTests")
struct RoutingMaterialSummarizerTests {
    @Test func locatorFindsAnExecutableOnTheGivenPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let found = LocalRuntimeLocator.find(
            .codex,
            environment: ["PATH": directory.path],
            extraDirectories: []
        )
        #expect(found == binary)
        #expect(
            LocalRuntimeLocator.find(
                .claude,
                environment: ["PATH": directory.path],
                extraDirectories: []
            ) == nil
        )
    }

    @Test func codexArgumentsStayReadOnlyAndDoNotSkipPermissions() {
        let directory = URL(fileURLWithPath: "/tmp/jelly-summary", isDirectory: true)
        let output = directory.appendingPathComponent("last-message.txt")
        let arguments = LocalRuntimeMaterialSummarizer.arguments(
            runtime: .codex,
            prompt: "只输出 JSON",
            directory: directory,
            outputFile: output
        )
        #expect(arguments.contains("--sandbox"))
        #expect(arguments.contains("read-only"))
        #expect(arguments.contains("--output-last-message"))
        #expect(arguments.contains(output.path))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
        #expect(arguments.last == "只输出 JSON")
    }

    @Test func missingLocalRuntimeStopsWithoutCallingTheCommand() async {
        let suite = "jelly-runtime-missing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = DigestSettingsStore(defaults: defaults)
        settings.setSummarySource(.localRuntime)
        let runner = RecordingSummaryRunner()
        let local = LocalRuntimeMaterialSummarizer(
            settings: settings,
            locate: { _ in nil },
            runner: runner
        )
        #expect(local.isConfigured)
        await #expect(throws: MaterialDigestPipelineError.localRuntimeUnavailable) {
            try await local.summarize(try routingSnapshot(), source: routingSource())
        }
        #expect(runner.calls == 0)
    }

    @Test func serviceSelectionDoesNotCallTheLocalCommand() async throws {
        let suite = "jelly-runtime-service-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = DigestSettingsStore(defaults: defaults)
        #expect(settings.save(endpoint: "https://api.example.com/v1", model: "gpt-test"))
        let credentials = InMemoryDigestCredentialStore()
        let runner = RecordingSummaryRunner()
        let routing = RoutingMaterialSummarizer(
            settings: settings,
            http: OpenAICompatibleMaterialSummarizer(settings: settings, credentials: credentials),
            local: LocalRuntimeMaterialSummarizer(settings: settings, locate: { _ in nil }, runner: runner)
        )
        #expect(routing.isConfigured == false)
        await #expect(throws: MaterialDigestPipelineError.modelNotConfigured) {
            try await routing.summarize(try routingSnapshot(), source: routingSource())
        }
        #expect(runner.calls == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_LOCAL"] == "1"))
    func liveLocalCodexProducesGroundedV3Summary() async throws {
        let suite = "jelly-live-local-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DigestSettingsStore(defaults: defaults)
        settings.setSummarySource(.localRuntime)
        settings.setLocalRuntime(.codex)
        let snapshot = try liveLocalSnapshot()
        let summarizer = LocalRuntimeMaterialSummarizer(settings: settings)
        let output = try await summarizer.summarize(
            snapshot,
            source: MaterialSource(
                inspirationID: InspirationID(),
                text: snapshot.blocks.map(\.text).joined(separator: "\n"),
                sourceChecksum: snapshot.sourceChecksum
            )
        )
        #expect(output.model == "codex")
        #expect(output.endpointHost == "local")
        try MaterialDigestEvidence.validateNewSummary(output.summary, against: snapshot)
    }
}

private final class RecordingSummaryRunner: SummaryCommandRunning, @unchecked Sendable {
    var calls = 0

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> SummaryCommandResult {
        calls += 1
        return SummaryCommandResult(standardOutput: "", outputFile: "", exitCode: 1)
    }
}

private func liveLocalSnapshot() throws -> MaterialSnapshot {
    let sourceChecksum = "live-local-codex"
    let blocks = [
        MaterialBlock(
            id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000d001")!),
            role: .body,
            text: "稳定的材料提炼首先要保留原始内容，再让用户主动决定何时生成摘要。",
            locator: .paragraph(index: 1),
            confidence: nil
        ),
        MaterialBlock(
            id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000d002")!),
            role: .body,
            text: "摘要中的结论必须能追溯到具体证据；来源读取不完整时，应明确告诉用户缺失了什么。",
            locator: .paragraph(index: 2),
            confidence: nil
        )
    ]
    let draft = MaterialSnapshot(
        sourceChecksum: sourceChecksum,
        contentFingerprint: "pending",
        blocks: blocks,
        coverage: .sufficient,
        provenance: .init(adapterIdentifier: "live-local", adapterVersion: "1", acquiredAt: .distantPast),
        createdAt: .distantPast
    )
    return MaterialSnapshot(
        sourceChecksum: sourceChecksum,
        contentFingerprint: try WorkspaceChecksum.materialSnapshotContentFingerprint(draft),
        blocks: blocks,
        coverage: draft.coverage,
        provenance: draft.provenance,
        createdAt: draft.createdAt
    )
}

private func routingSnapshot() throws -> MaterialSnapshot {
    let blocks = [
        MaterialBlock(
            id: MaterialBlockID(),
            role: .body,
            text: "一段可以提炼的正文。",
            locator: .paragraph(index: 1),
            confidence: nil
        )
    ]
    let draft = MaterialSnapshot(
        sourceChecksum: "routing-checksum",
        contentFingerprint: "pending",
        blocks: blocks,
        coverage: .sufficient,
        provenance: .init(adapterIdentifier: "fixture", adapterVersion: "1", acquiredAt: .distantPast),
        createdAt: .distantPast
    )
    return MaterialSnapshot(
        sourceChecksum: draft.sourceChecksum,
        contentFingerprint: try WorkspaceChecksum.materialSnapshotContentFingerprint(draft),
        blocks: blocks,
        coverage: draft.coverage,
        provenance: draft.provenance,
        createdAt: draft.createdAt
    )
}

private func routingSource() -> MaterialSource {
    MaterialSource(
        inspirationID: InspirationID(),
        text: "一段可以提炼的正文。",
        sourceChecksum: "routing-checksum"
    )
}
