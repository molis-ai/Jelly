import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WorkspaceSyncServiceTests")
@MainActor
struct WorkspaceSyncServiceTests {
    private struct Fixture {
        let folder: URL
        let root: URL
        let cleanup: () -> Void
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-sync-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("iCloud Drive/Jelly 同步", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Fixture(folder: folder, root: root) { try? FileManager.default.removeItem(at: root) }
    }

    private func device(_ name: String, fixture: Fixture) async throws -> (WorkspaceSyncService, WorkspaceStore, () -> Void) {
        let suite = "jelly-sync-\(name)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let service = WorkspaceSyncService(
            store: store,
            dataRoot: fixture.root.appendingPathComponent(name, isDirectory: true),
            settings: SyncSettings(defaults: defaults),
            deviceName: name
        )
        return (service, store, { defaults.removePersistentDomain(forName: suite) })
    }

    private func addItem(_ title: String, to store: WorkspaceStore) async throws -> UUID {
        let today = CalendarDate.localDay(containing: Date(), in: .current)
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: title,
            categoryID: store.calendarState.uncategorizedID,
            schedule: CalendarSchedule(startDate: today, endDate: today, startTime: nil, endTime: nil),
            completedAt: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        _ = try await store.sendWorkspace(.calendar(.createItem(item)))
        return item.id
    }

    @Test func macAndPhoneExchangeThroughTheSharedFolder() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let (mac, macStore, cleanMac) = try await device("Mac", fixture: fixture)
        let (phone, phoneStore, cleanPhone) = try await device("iPhone", fixture: fixture)
        defer { cleanMac(); cleanPhone() }

        let macItem = try await addItem("Mac 上记的", to: macStore)
        let inspiration = Inspiration.text(rawText: "地铁上的想法", categoryID: phoneStore.calendarState.uncategorizedID, now: Date())
        _ = try await phoneStore.sendWorkspace(.createInspiration(.init(inspiration: inspiration)))

        await mac.enable(folder: .path(fixture.folder.path))
        await phone.enable(folder: .path(fixture.folder.path))
        await mac.syncNow()

        #expect(macStore.state.inspirations.values.map(\.rawText) == ["地铁上的想法"])
        #expect(phoneStore.state.calendar.items[macItem]?.title == "Mac 上记的")
        #expect(macStore.state.calendar.uncategorizedID == phoneStore.state.calendar.uncategorizedID)
        let files = try FileManager.default.contentsOfDirectory(atPath: SyncFolderStore.devicesDirectory(in: fixture.folder).path)
        #expect(files.count == 2)
        if case let .synced(_, summary) = mac.status {
            #expect(summary.contains("iPhone"))
        } else {
            Issue.record("unexpected status \(mac.status)")
        }

        // Deleting on the phone removes it on the Mac.
        _ = try await phoneStore.sendWorkspace(.calendar(.deleteItem(macItem)))
        await phone.syncNow()
        await mac.syncNow()
        #expect(macStore.state.calendar.items[macItem] == nil)

        // The merge is one undoable step on the receiving device.
        #expect(macStore.latestUndoLabel == "同步")
    }

    @Test func missingFolderAndDisabledSyncDoNothing() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let (service, store, clean) = try await device("Mac", fixture: fixture)
        defer { clean() }
        _ = try await addItem("本机的事", to: store)
        await service.syncNow()
        #expect(service.status == .off)
        service.settings.isEnabled = true
        await service.syncNow()
        #expect(service.status == .failed("还没有选同步文件夹。"))
    }

    @Test func evictedICloudFilesAreRequestedNotMisread() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let directory = SyncFolderStore.devicesDirectory(in: fixture.folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: directory.appendingPathComponent(".PEER.json.icloud"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("BROKEN.json"))
        let read = SyncFolderStore.readPeers(in: fixture.folder, excluding: "ME")
        #expect(read.documents.isEmpty)
        #expect(read.pending == 1)
        #expect(read.unreadable == 1)
    }
}
