import Foundation
import Testing
@testable import CalendarApp

@Suite("AppEnvironmentWorkspaceCutoverTests")
@MainActor
struct AppEnvironmentWorkspaceCutoverTests {
    @Test func productionEnvironmentEnablesNotesAndInspiration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-7-environment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment.live(environment: [
            "JELLY_ACCEPTANCE_DATA_DIRECTORY": root.path
        ])

        #expect(environment.features == .production)
        #expect(environment.features.notes == true)
        #expect(environment.features.inspiration == true)
        let plannerName = String(describing: type(of: environment.decompositionPlanner))
        #expect(!plannerName.localizedCaseInsensitiveContains("scripted"))
        #expect(!plannerName.localizedCaseInsensitiveContains("mock"))
        #expect(!plannerName.localizedCaseInsensitiveContains("fixture"))
    }

    @Test func liveEnvironmentComposesOneWorkspaceStoreFromTheResolvedDataDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-6c-environment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = try AppEnvironment.live(environment: [
            "JELLY_ACCEPTANCE_DATA_DIRECTORY": root.path
        ])

        #expect(environment.dataURLs.root == root.standardizedFileURL)
        await environment.store.load()
        #expect(environment.store.phase == .ready)
        #expect(environment.store.calendarState.uncategorizedID != UUID())
    }

    @Test func startupFailureIsReturnedForPresentationInsteadOfTerminatingTheProcess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-startup-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = AppEnvironment.loadLive(environment: [
            "JELLY_ACCEPTANCE_DATA_DIRECTORY": root.path
        ])
        guard case .failure = result else {
            Issue.record("数据根路径不可用时必须返回失败，由 UI 呈现")
            return
        }
    }
}
