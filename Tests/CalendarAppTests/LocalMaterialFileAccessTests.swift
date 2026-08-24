import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("LocalMaterialFileAccessTests")
struct LocalMaterialFileAccessTests {
    @Test func scopedAccessAlwaysStopsAfterThrownBody() async throws {
        let recorder = FileScopeRecorder()
        let expectedURL = URL(fileURLWithPath: "/tmp/jelly-material.txt")
        let access = LocalMaterialFileAccess(
            resolve: { _ in expectedURL },
            start: { url in
                recorder.recordStart(url)
                return true
            },
            stop: { url in recorder.recordStop(url) }
        )

        await #expect(throws: FileAccessFixtureError.failed) {
            try await access.withAccess(
                to: FileReference(bookmarkData: Data([1]), displayName: "材料.txt")
            ) { url in
                #expect(url == expectedURL)
                throw FileAccessFixtureError.failed
            }
        }

        #expect(recorder.startCount == 1)
        #expect(recorder.stopCount == 1)
    }

    @Test func staleBookmarkIsRejectedBeforeStartingAccess() async {
        let recorder = FileScopeRecorder()
        let access = LocalMaterialFileAccess(
            resolve: { _ in throw LocalMaterialFileAccessError.staleBookmark },
            start: { url in
                recorder.recordStart(url)
                return true
            },
            stop: { url in recorder.recordStop(url) }
        )

        await #expect(throws: LocalMaterialFileAccessError.staleBookmark) {
            try await access.withAccess(
                to: FileReference(bookmarkData: Data([1]), displayName: "旧文件.txt")
            ) { _ in true }
        }
        #expect(recorder.startCount == 0)
        #expect(recorder.stopCount == 0)
    }
}

private enum FileAccessFixtureError: Error {
    case failed
}

private final class FileScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [URL] = []
    private var stops: [URL] = []

    var startCount: Int { lock.withLock { starts.count } }
    var stopCount: Int { lock.withLock { stops.count } }

    func recordStart(_ url: URL) { lock.withLock { starts.append(url) } }
    func recordStop(_ url: URL) { lock.withLock { stops.append(url) } }
}
