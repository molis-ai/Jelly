import CalendarDomain
import Foundation

/// One alert Jelly wants the platform to deliver: an Apple Reminders entry on
/// the Mac (so iCloud rings the phone), or a local notification on iOS.
public struct ReminderRequest: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public let title: String
    public let notes: String
    public let fireDate: Date
    public let dueDay: CalendarDate
    public let dueTime: MinuteOfDay?

    public init(key: String, title: String, notes: String, fireDate: Date, dueDay: CalendarDate, dueTime: MinuteOfDay?) {
        self.key = key
        self.title = title
        self.notes = notes
        self.fireDate = fireDate
        self.dueDay = dueDay
        self.dueTime = dueTime
    }

    /// Changes whenever anything the user would see in Reminders changes.
    public var fingerprint: String {
        let parts = [
            title,
            notes,
            String(Int(fireDate.timeIntervalSince1970)),
            "\(dueDay.year)-\(dueDay.month)-\(dueDay.day)",
            dueTime.map { String($0.value) } ?? "-"
        ]
        return WorkspaceChecksum.sha256Hex(Data(parts.joined(separator: "\u{1F}").utf8))
    }
}

public struct ReviewReminderConfiguration: Equatable, Sendable {
    public var time: MinuteOfDay
    public var dueCount: Int

    public init(time: MinuteOfDay, dueCount: Int) {
        self.time = time
        self.dueCount = dueCount
    }
}

public enum ReminderPlanner {
    public static let reviewKey = "review"
    /// Keep a fired reminder around for a week so the phone list still shows it.
    public static let retention: TimeInterval = 7 * 86_400

    public static func itemKey(_ id: UUID) -> String { "item:\(id.uuidString)" }

    public static func occurrenceKey(_ key: OccurrenceKey) -> String {
        let day = key.originalDate
        return String(format: "occurrence:%@/%04d-%02d-%02d", key.seriesID.uuidString, day.year, day.month, day.day)
    }

    public static func requests(
        in state: WorkspaceState,
        now: Date,
        timeZone: TimeZone = .current,
        horizonDays: Int = 60,
        review: ReviewReminderConfiguration? = nil
    ) -> [ReminderRequest] {
        let horizon = now.addingTimeInterval(TimeInterval(horizonDays) * 86_400)
        var result: [ReminderRequest] = []
        for item in state.calendar.items.values {
            guard item.completedAt == nil,
                  let reminder = item.reminder,
                  // Civil time: 15:00 means 15:00 wherever the user is now.
                  let fire = reminder.fireDate(for: item.schedule, timeZone: timeZone),
                  fire >= now.addingTimeInterval(-retention),
                  fire <= horizon
            else { continue }
            result.append(ReminderRequest(
                key: itemKey(item.id),
                title: item.title,
                notes: notes(for: item, reminder: reminder),
                fireDate: fire,
                dueDay: item.schedule.startDate,
                dueTime: item.schedule.startTime
            ))
        }
        let graph = state.calendar.recurrence
        let window = CalendarDateRange(
            start: CalendarDate.localDay(containing: now.addingTimeInterval(-retention), in: timeZone),
            end: CalendarDate.localDay(containing: horizon, in: timeZone)
        )
        for series in graph.series.values {
            guard let reminder = series.reminder else { continue }
            let occurrences = RecurrenceEngine.occurrences(
                of: series,
                in: window,
                exceptions: graph.exceptions,
                completions: graph.completions
            )
            for occurrence in occurrences where occurrence.completedAt == nil {
                guard let fire = reminder.adapted(to: occurrence.schedule)
                    .fireDate(for: occurrence.schedule, timeZone: timeZone),
                      fire >= now.addingTimeInterval(-retention),
                      fire <= horizon
                else { continue }
                result.append(ReminderRequest(
                    key: occurrenceKey(occurrence.key),
                    title: occurrence.title,
                    notes: notes(title: reminder.title, body: occurrence.notes),
                    fireDate: fire,
                    dueDay: occurrence.schedule.startDate,
                    dueTime: occurrence.schedule.startTime
                ))
            }
        }
        if let review, review.dueCount > 0, let request = reviewRequest(review, now: now, timeZone: timeZone) {
            result.append(request)
        }
        return result.sorted { ($0.fireDate, $0.key) < ($1.fireDate, $1.key) }
    }

    static func reviewRequest(
        _ review: ReviewReminderConfiguration,
        now: Date,
        timeZone: TimeZone
    ) -> ReminderRequest? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard var day = CalendarDate(year: parts.year!, month: parts.month!, day: parts.day!) else { return nil }
        let reminder = ItemReminder.onStartDay(at: review.time)
        func fire(on day: CalendarDate) -> Date? {
            let schedule = try? CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil)
            return schedule.flatMap { reminder.fireDate(for: $0, timeZone: timeZone) }
        }
        guard var date = fire(on: day) else { return nil }
        if date <= now {
            day = day.addingDays(1)
            guard let next = fire(on: day) else { return nil }
            date = next
        }
        return ReminderRequest(
            key: reviewKey,
            title: "回顾 \(review.dueCount) 条旧灵感",
            notes: "打开 Jelly › 灵感 › 回顾：逐条留着、变成待办或丢掉。",
            fireDate: date,
            dueDay: day,
            dueTime: review.time
        )
    }

    private static func notes(for item: CalendarItem, reminder: ItemReminder) -> String {
        notes(title: reminder.title, body: item.notes)
    }

    private static func notes(title: String, body: String) -> String {
        var lines = ["来自 Jelly · \(title)"]
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append(String(trimmed.prefix(500))) }
        return lines.joined(separator: "\n")
    }
}

/// What Jelly last wrote for each request key, persisted next to the data.
public struct ReminderSyncMapping: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var identifier: String
        public var fingerprint: String

        public init(identifier: String, fingerprint: String) {
            self.identifier = identifier
            self.fingerprint = fingerprint
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }
}

public struct ReminderSyncPlan: Equatable, Sendable {
    public var creates: [ReminderRequest] = []
    public var updates: [(identifier: String, request: ReminderRequest)] = []
    public var deletes: [(key: String, identifier: String)] = []
    public var unchanged: [(key: String, identifier: String)] = []

    public init() {}

    public var isEmpty: Bool { creates.isEmpty && updates.isEmpty && deletes.isEmpty }

    public static func == (lhs: ReminderSyncPlan, rhs: ReminderSyncPlan) -> Bool {
        lhs.creates == rhs.creates
            && lhs.updates.map(\.identifier) == rhs.updates.map(\.identifier)
            && lhs.updates.map(\.request) == rhs.updates.map(\.request)
            && lhs.deletes.map(\.key) == rhs.deletes.map(\.key)
            && lhs.deletes.map(\.identifier) == rhs.deletes.map(\.identifier)
            && lhs.unchanged.map(\.key) == rhs.unchanged.map(\.key)
    }
}

public enum ReminderSyncPlanner {
    public static func plan(requests: [ReminderRequest], mapping: ReminderSyncMapping) -> ReminderSyncPlan {
        var plan = ReminderSyncPlan()
        let wanted = Dictionary(requests.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for request in requests {
            guard let existing = mapping.entries[request.key] else {
                plan.creates.append(request)
                continue
            }
            if existing.fingerprint == request.fingerprint {
                plan.unchanged.append((request.key, existing.identifier))
            } else {
                plan.updates.append((existing.identifier, request))
            }
        }
        for (key, entry) in mapping.entries.sorted(by: { $0.key < $1.key }) where wanted[key] == nil {
            plan.deletes.append((key, entry.identifier))
        }
        return plan
    }
}
