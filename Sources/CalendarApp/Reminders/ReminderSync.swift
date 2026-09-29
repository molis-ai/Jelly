import CalendarDomain
import EventKit
import Foundation
import Observation
import WorkspaceDomain

enum ReminderAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

enum ExistingReminderState: Equatable, Sendable {
    case missing
    case open
    case completed
}

/// The slice of Apple Reminders Jelly needs. A fake stands in for tests.
@MainActor
protocol ReminderStoreGateway: AnyObject {
    var authorization: ReminderAuthorization { get }
    func requestAccess() async -> Bool
    /// Finds or creates the list and returns its identifier.
    func prepareList(named name: String) throws -> String
    func state(of identifier: String) -> ExistingReminderState
    func create(_ request: ReminderRequest, inList listID: String) throws -> String
    func update(_ identifier: String, with request: ReminderRequest) throws
    func delete(_ identifier: String) throws
    func commit() throws
}

enum ReminderGatewayError: Error, Equatable {
    case listUnavailable
    case reminderUnavailable
}

@MainActor
final class EventKitReminderGateway: ReminderStoreGateway {
    private let store = EKEventStore()

    var authorization: ReminderAuthorization {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: .notDetermined
        case .fullAccess: .authorized
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    func prepareList(named name: String) throws -> String {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == name && $0.allowsContentModifications }) {
            return existing.calendarIdentifier
        }
        // Prefer the account new reminders already go to (usually iCloud), so
        // the list syncs to the phone.
        let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local })
        guard let source else { throw ReminderGatewayError.listUnavailable }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = name
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list.calendarIdentifier
    }

    func state(of identifier: String) -> ExistingReminderState {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return .missing }
        return reminder.isCompleted ? .completed : .open
    }

    func create(_ request: ReminderRequest, inList listID: String) throws -> String {
        guard let list = store.calendar(withIdentifier: listID) else { throw ReminderGatewayError.listUnavailable }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        apply(request, to: reminder)
        try store.save(reminder, commit: false)
        return reminder.calendarItemIdentifier
    }

    func update(_ identifier: String, with request: ReminderRequest) throws {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw ReminderGatewayError.reminderUnavailable
        }
        apply(request, to: reminder)
        try store.save(reminder, commit: false)
    }

    func delete(_ identifier: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        try store.remove(reminder, commit: false)
    }

    func commit() throws {
        try store.commit()
    }

    private func apply(_ request: ReminderRequest, to reminder: EKReminder) {
        reminder.title = request.title
        reminder.notes = request.notes
        var due = DateComponents(year: request.dueDay.year, month: request.dueDay.month, day: request.dueDay.day)
        if let time = request.dueTime {
            due.hour = time.value / 60
            due.minute = time.value % 60
        }
        due.calendar = Calendar(identifier: .gregorian)
        reminder.dueDateComponents = due
        reminder.alarms?.forEach { reminder.removeAlarm($0) }
        reminder.addAlarm(EKAlarm(absoluteDate: request.fireDate))
    }
}

struct ReminderSyncSettings {
    static let enabledKey = "reminders.sync.enabled.v1"
    static let reviewEnabledKey = "reminders.review.enabled.v1"
    static let reviewTimeKey = "reminders.review.minuteOfDay.v1"
    static let listName = "Jelly"

    let defaults: UserDefaults

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var reviewEnabled: Bool {
        get { defaults.object(forKey: Self.reviewEnabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.reviewEnabledKey) }
    }

    var reviewTime: MinuteOfDay {
        get {
            (defaults.object(forKey: Self.reviewTimeKey) as? Int).flatMap { MinuteOfDay(hour: $0 / 60, minute: $0 % 60) }
                ?? MinuteOfDay(hour: 21, minute: 0)!
        }
        nonmutating set { defaults.set(newValue.value, forKey: Self.reviewTimeKey) }
    }
}

struct ReminderSyncOutcome: Equatable, Sendable {
    var created = 0
    var updated = 0
    var removed = 0
    var leftAlone = 0

    var summary: String {
        if created + updated + removed == 0 { return "已是最新" }
        return "新增 \(created) · 更新 \(updated) · 移除 \(removed)"
    }
}

/// Mirrors reminder-carrying items into the "Jelly" list of Apple Reminders.
/// One-way: Jelly writes; what the user completes or deletes on the phone is
/// left alone until the item changes in Jelly again.
@MainActor
@Observable
final class ReminderSyncService {
    private let store: WorkspaceStore
    private let gateway: any ReminderStoreGateway
    private let mappingURL: URL
    let settings: ReminderSyncSettings
    private let clock: @Sendable () -> Date
    private var pendingSync: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    var diagnostics: (String) -> Void = { _ in }

    private(set) var lastOutcome: ReminderSyncOutcome?
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false

    init(
        store: WorkspaceStore,
        gateway: any ReminderStoreGateway,
        mappingURL: URL,
        settings: ReminderSyncSettings,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.gateway = gateway
        self.mappingURL = mappingURL
        self.settings = settings
        self.clock = clock
    }

    var authorization: ReminderAuthorization { gateway.authorization }

    /// Follows every committed change, plus an hourly tick so the daily
    /// review reminder rolls forward even when nothing is edited.
    func start() {
        guard observer == nil else { return }
        if settings.isEnabled, gateway.authorization == .notDetermined {
            // Turned on before (e.g. a reinstall reset privacy): ask again.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.gateway.requestAccess() {
                    await self.syncNow()
                } else {
                    self.lastError = "没有获得提醒事项权限。可在系统设置 › 隐私与安全性 › 提醒事项 里允许 Jelly。"
                }
            }
        }
        observer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let store = self?.store else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = store.statePublicationGeneration
                    } onChange: {
                        continuation.resume()
                    }
                }
                self?.scheduleSync()
            }
        }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.scheduleSync(after: .seconds(1))
                try? await Task.sleep(for: .seconds(3_600))
            }
        }
    }

    func enable() async -> Bool {
        if gateway.authorization != .authorized {
            guard await gateway.requestAccess() else {
                lastError = "没有获得提醒事项权限。可在系统设置 › 隐私与安全性 › 提醒事项 里允许 Jelly。"
                return false
            }
        }
        settings.isEnabled = true
        await syncNow()
        return lastError == nil
    }

    /// Turning it off takes back the open reminders Jelly wrote; ones the
    /// user already completed stay as history.
    func disable() async {
        settings.isEnabled = false
        pendingSync?.cancel()
        guard gateway.authorization == .authorized else { return }
        let mapping = loadMapping()
        var removed = 0
        for entry in mapping.entries.values where gateway.state(of: entry.identifier) == .open {
            if (try? gateway.delete(entry.identifier)) != nil { removed += 1 }
        }
        try? gateway.commit()
        try? saveMapping(ReminderSyncMapping())
        lastOutcome = ReminderSyncOutcome(removed: removed)
        lastSyncedAt = clock()
        lastError = nil
        diagnostics("reminders disabled; removed \(removed)")
    }

    /// Coalesces bursts of edits into one write a moment later.
    func scheduleSync(after delay: Duration = .seconds(2)) {
        guard settings.isEnabled else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard settings.isEnabled else { return }
        guard gateway.authorization == .authorized else {
            lastError = "没有提醒事项权限，同步已暂停。"
            diagnostics("reminders sync skipped: authorization \(gateway.authorization)")
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let now = clock()
        let review = settings.reviewEnabled
            ? ReviewReminderConfiguration(
                time: settings.reviewTime,
                dueCount: InspirationReviewQueue.due(in: store.state, now: now).count
            )
            : nil
        let requests = ReminderPlanner.requests(in: store.state, now: now, review: review)
        var mapping = loadMapping()
        let plan = ReminderSyncPlanner.plan(requests: requests, mapping: mapping)
        var outcome = ReminderSyncOutcome()
        do {
            let listID = try gateway.prepareList(named: ReminderSyncSettings.listName)
            for request in plan.creates {
                let identifier = try gateway.create(request, inList: listID)
                mapping.entries[request.key] = .init(identifier: identifier, fingerprint: request.fingerprint)
                outcome.created += 1
            }
            for (identifier, request) in plan.updates {
                switch gateway.state(of: identifier) {
                case .open:
                    try gateway.update(identifier, with: request)
                    mapping.entries[request.key] = .init(identifier: identifier, fingerprint: request.fingerprint)
                    outcome.updated += 1
                case .missing, .completed:
                    // Changed in Jelly after the user cleared it on the phone:
                    // the new version deserves a fresh reminder.
                    let fresh = try gateway.create(request, inList: listID)
                    mapping.entries[request.key] = .init(identifier: fresh, fingerprint: request.fingerprint)
                    outcome.created += 1
                }
            }
            for (key, identifier) in plan.deletes {
                if gateway.state(of: identifier) == .open {
                    try gateway.delete(identifier)
                    outcome.removed += 1
                }
                mapping.entries[key] = nil
            }
            outcome.leftAlone = plan.unchanged.count
            try gateway.commit()
            try saveMapping(mapping)
            lastOutcome = outcome
            lastSyncedAt = now
            lastError = nil
            diagnostics("reminders synced: \(outcome.summary); mapped \(mapping.entries.count)")
        } catch {
            lastError = "写入提醒事项失败，下次改动时会再试。"
            diagnostics("reminders sync failed: \(error)")
        }
    }

    private func loadMapping() -> ReminderSyncMapping {
        guard let data = try? Data(contentsOf: mappingURL),
              let mapping = try? JSONDecoder().decode(ReminderSyncMapping.self, from: data)
        else { return ReminderSyncMapping() }
        return mapping
    }

    private func saveMapping(_ mapping: ReminderSyncMapping) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(
            at: mappingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(mapping).write(to: mappingURL, options: .atomic)
    }
}
