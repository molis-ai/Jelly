import Foundation
import WorkspaceDomain

enum LocalRuntimeLocator {
    static func find(
        _ runtime: LocalSummaryRuntime,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        extraDirectories: [URL] = Self.defaultExtraDirectories(),
        fileManager: FileManager = .default
    ) -> URL? {
        var directories: [URL] = []
        if let path = environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
            })
        }
        directories.append(contentsOf: extraDirectories)
        let command = runtime.commandName
        for directory in directories {
            let candidate = directory.appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func defaultExtraDirectories() -> [URL] {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        ]
        #else
        return []
        #endif
    }
}

struct SummaryCommandResult: Sendable {
    var standardOutput: String
    var outputFile: String
    var exitCode: Int32
}

protocol SummaryCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> SummaryCommandResult
}

struct LiveSummaryCommandRunner: SummaryCommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> SummaryCommandResult {
        #if os(macOS)
        let outputURL = workingDirectory.appendingPathComponent("last-message.txt")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let stdoutTask = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let stderrTask = Task.detached { error.fileHandleForReading.readDataToEndOfFile() }
        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
            }
        } onCancel: {
            process.terminate()
        }
        _ = await stderrTask.value
        let stdout = String(decoding: await stdoutTask.value, as: UTF8.self)
        let written = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return SummaryCommandResult(
            standardOutput: stdout,
            outputFile: written,
            exitCode: exitCode
        )
        #else
        throw MaterialDigestPipelineError.localRuntimeUnavailable
        #endif
    }
}

final class LocalRuntimeMaterialSummarizer: MaterialSummarizing, @unchecked Sendable {
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

    func summarize(
        _ snapshot: MaterialSnapshot,
        source: MaterialSource
    ) async throws -> MaterialSummarizerOutput {
        guard settings.summarySource == .localRuntime else {
            throw MaterialDigestPipelineError.modelNotConfigured
        }
        let runtime = settings.localRuntime
        guard let executable = locate(runtime) else {
            throw MaterialDigestPipelineError.localRuntimeUnavailable
        }
        let prompt = try OpenAICompatibleMaterialSummarizer.instruction(snapshot: snapshot, source: source)
        guard prompt.utf8.count <= 180_000 else {
            throw MaterialDigestPipelineError.contextTooLong
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("last-message.txt")
        let arguments = Self.arguments(
            runtime: runtime,
            prompt: prompt,
            directory: directory,
            outputFile: outputURL
        )
        let result: SummaryCommandResult
        do {
            result = try await runner.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.summarizationFailed
        }
        let text = result.outputFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.standardOutput
            : result.outputFile
        guard result.exitCode == 0 || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MaterialDigestPipelineError.summarizationFailed
        }
        return try OpenAICompatibleMaterialSummarizer.finish(
            modelText: text,
            snapshot: snapshot,
            source: source,
            endpointHost: "local",
            model: runtime.rawValue
        )
    }

    static func arguments(
        runtime: LocalSummaryRuntime,
        prompt: String,
        directory: URL,
        outputFile: URL
    ) -> [String] {
        switch runtime {
        case .codex:
            [
                "exec",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "--skip-git-repo-check",
                "--json",
                "--cd", directory.path,
                "--sandbox", "read-only",
                "--output-last-message", outputFile.path,
                prompt
            ]
        case .claude:
            ["-p", prompt, "--output-format", "text", "--tools", "", "--no-session-persistence"]
        }
    }
}

final class RoutingMaterialSummarizer: MaterialSummarizing, @unchecked Sendable {
    private let settings: DigestSettingsStore
    private let http: OpenAICompatibleMaterialSummarizer
    private let local: LocalRuntimeMaterialSummarizer

    init(
        settings: DigestSettingsStore,
        http: OpenAICompatibleMaterialSummarizer,
        local: LocalRuntimeMaterialSummarizer
    ) {
        self.settings = settings
        self.http = http
        self.local = local
    }

    var isConfigured: Bool {
        if settings.summarySource == .localRuntime {
            return local.isConfigured
        }
        return http.isConfigured
    }

    func summarize(
        _ snapshot: MaterialSnapshot,
        source: MaterialSource
    ) async throws -> MaterialSummarizerOutput {
        if settings.summarySource == .localRuntime {
            return try await local.summarize(snapshot, source: source)
        }
        return try await http.summarize(snapshot, source: source)
    }
}
