import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@MainActor
final class FakeReminderGateway: ReminderStoreGateway {
    var authorization: ReminderAuthorization = .notDetermined
    var grantsAccess = true
    var lists: [String: String] = [:]
    var reminders: [String: (request: ReminderRequest, completed: Bool)] = [:]
    var commits = 0
    private var next = 0

    func requestAccess() async -> Bool {
        authorization = grantsAccess ? .authorized : .denied
        return grantsAccess
    }

    func prepareList(named name: String) throws -> String {
        if let id = lists[name] { return id }
        lists[name] = "list-\(name)"
        return lists[name]!
    }

    func state(of identifier: String) -> ExistingReminderState {
        guard let reminder = reminders[identifier] else { return .missing }
        return reminder.completed ? .completed : .open
    }

    func create(_ request: ReminderRequest, inList listID: String) throws -> String {
        next += 1
        let id = "ek-\(next)"
        reminders[id] = (request, false)
        return id
    }

    func update(_ identifier: String, with request: ReminderRequest) throws {
        reminders[identifier]?.request = request
    }

    func delete(_ identifier: String) throws {
        reminders[identifier] = nil
    }

    func commit() throws { commits += 1 }

    var openTitles: [String] {
        reminders.values.filter { !$0.completed }.map(\.request.title).sorted()
    }
}

@Suite("ReminderSyncServiceTests")
@MainActor
struct ReminderSyncServiceTests {
    private let day = CalendarDate.today(now: Date()).addingDays(2)

    private func environment() throws -> (ReminderSyncSettings, URL, () -> Void) {
        let suite = "jelly-reminders-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        return (
            ReminderSyncSettings(defaults: defaults),
            directory.appendingPathComponent("reminder-sync.json"),
            {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
        )
    }

    private func item(_ title: String, reminder: ItemReminder?, categoryID: UUID) throws -> CalendarItem {
        try CalendarItem(
            id: UUID(),
            kind: .task,
            title: title,
            categoryID: categoryID,
            schedule: CalendarSchedule(
                startDate: day,
                endDate: day,
                startTime: MinuteOfDay(hour: 15, minute: 0),
                endTime: MinuteOfDay(hour: 16, minute: 0)
            ),
            reminder: reminder,
            completedAt: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    @Test func enablingAsksOnceThenMirrorsEditsAndDeletes() async throws {
        let (settings, mappingURL, cleanup) = try environment()
        defer { cleanup() }
        settings.reviewEnabled = false
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let gateway = FakeReminderGateway()
        let service = ReminderSyncService(store: store, gateway: gateway, mappingURL: mappingURL, settings: settings)
        let categoryID = store.calendarState.uncategorizedID

        var meeting = try item("开会", reminder: .beforeStart(minutes: 10), categoryID: categoryID)
        _ = try await store.sendWorkspace(.calendar(.createItem(meeting)))
        _ = try await store.sendWorkspace(.calendar(.createItem(try item("不提醒", reminder: nil, categoryID: categoryID))))

        #expect(await service.enable())
        #expect(gateway.authorization == .authorized)
        #expect(gateway.openTitles == ["开会"])
        #expect(gateway.lists.keys.sorted() == ["Jelly"])

        meeting.title = "开会（3 楼）"
        _ = try await store.sendWorkspace(.calendar(.updateItem(meeting)))
        await service.syncNow()
        #expect(gateway.openTitles == ["开会（3 楼）"])
        #expect(service.lastOutcome?.updated == 1)

        // A fresh service reads the saved mapping instead of duplicating.
        let restarted = ReminderSyncService(store: store, gateway: gateway, mappingURL: mappingURL, settings: settings)
        await restarted.syncNow()
        #expect(gateway.reminders.count == 1)
        #expect(restarted.lastOutcome?.summary == "已是最新")

        _ = try await store.sendWorkspace(.calendar(.deleteItem(meeting.id)))
        await restarted.syncNow()
        #expect(gateway.reminders.isEmpty)
    }

    @Test func phoneSideCompletionIsRespectedUntilJellyChangesTheItem() async throws {
        let (settings, mappingURL, cleanup) = try environment()
        defer { cleanup() }
        settings.reviewEnabled = false
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let gateway = FakeReminderGateway()
        let service = ReminderSyncService(store: store, gateway: gateway, mappingURL: mappingURL, settings: settings)
        var call = try item("回电话", reminder: .beforeStart(minutes: 0), categoryID: store.calendarState.uncategorizedID)
        _ = try await store.sendWorkspace(.calendar(.createItem(call)))
        #expect(await service.enable())
        let first = try #require(gateway.reminders.keys.first)

        gateway.reminders[first]?.completed = true
        await service.syncNow()
        #expect(gateway.openTitles.isEmpty)

        call.title = "回电话给房东"
        _ = try await store.sendWorkspace(.calendar(.updateItem(call)))
        await service.syncNow()
        #expect(gateway.openTitles == ["回电话给房东"])
        #expect(gateway.reminders[first]?.completed == true)

        _ = try await store.sendWorkspace(.calendar(.deleteItem(call.id)))
        gateway.reminders = gateway.reminders.mapValues { ($0.request, true) }
        await service.syncNow()
        #expect(gateway.reminders.count == 2)
    }

    @Test func deniedAccessLeavesSyncOff() async throws {
        let (settings, mappingURL, cleanup) = try environment()
        defer { cleanup() }
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let gateway = FakeReminderGateway()
        gateway.grantsAccess = false
        let service = ReminderSyncService(store: store, gateway: gateway, mappingURL: mappingURL, settings: settings)
        #expect(!(await service.enable()))
        #expect(!settings.isEnabled)
        #expect(service.lastError?.contains("隐私与安全性") == true)
    }

    @Test func dueReviewAddsOneDailyReminder() async throws {
        let (settings, mappingURL, cleanup) = try environment()
        defer { cleanup() }
        var workspace = WorkspaceState.empty(calendar: makeEmptyState())
        let old = Inspiration.text(
            rawText: "一周前的想法",
            categoryID: workspace.calendar.uncategorizedID,
            now: Date().addingTimeInterval(-7 * 86_400)
        )
        workspace.inspirations[old.id] = old
        let store = WorkspaceStore(initialState: workspace, repository: InMemoryWorkspaceRepository(workspace: workspace))
        await store.load()
        let gateway = FakeReminderGateway()
        let service = ReminderSyncService(store: store, gateway: gateway, mappingURL: mappingURL, settings: settings)
        #expect(await service.enable())
        #expect(gateway.openTitles == ["回顾 1 条旧灵感"])
    }

    @Test func turningOffTakesBackOpenRemindersButKeepsCompletedOnes() async throws {
        let (settings, mappingURL, cleanup) = try environment()
        defer { cleanup() }
        settings.reviewEnabled = false
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let gateway = FakeReminderGateway()
        let service = ReminderSyncService(store: store, gateway: gateway, mappingURL: mappingURL, settings: settings)
        let categoryID = store.calendarState.uncategorizedID
        _ = try await store.sendWorkspace(.calendar(.createItem(try item("开会", reminder: .beforeStart(minutes: 5), categoryID: categoryID))))
        _ = try await store.sendWorkspace(.calendar(.createItem(try item("交房租", reminder: .beforeStart(minutes: 0), categoryID: categoryID))))
        #expect(await service.enable())
        let paid = try #require(gateway.reminders.first { $0.value.request.title == "交房租" }?.key)
        gateway.reminders[paid]?.completed = true

        await service.disable()
        #expect(!settings.isEnabled)
        #expect(gateway.openTitles.isEmpty)
        #expect(gateway.reminders.keys.sorted() == [paid])
        #expect(service.lastOutcome?.removed == 1)
    }

    @Test func previouslyEnabledSyncAsksForPermissionAgainOnStart() async throws {
        let (settings, mappingURL, cleanup) = try environment()
        defer { cleanup() }
        settings.isEnabled = true
        settings.reviewEnabled = false
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        _ = try await store.sendWorkspace(.calendar(.createItem(try item("开会", reminder: .beforeStart(minutes: 5), categoryID: store.calendarState.uncategorizedID))))
        let gateway = FakeReminderGateway()
        let service = ReminderSyncService(store: store, gateway: gateway, mappingURL: mappingURL, settings: settings)
        service.start()
        #expect(await eventually { gateway.openTitles == ["开会"] })
        #expect(gateway.authorization == .authorized)
    }
}
