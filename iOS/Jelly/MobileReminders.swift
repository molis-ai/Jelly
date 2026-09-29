import CalendarDomain
import Foundation
import UserNotifications
import WorkspaceDomain

enum MobileReminderOptions {
    static let allDayTimes: [MinuteOfDay] = [8, 9, 12, 18, 20].compactMap { MinuteOfDay(hour: $0, minute: 0) }

    static func options(usesTime: Bool) -> [ItemReminder] {
        usesTime
            ? ItemReminder.allowedLeadMinutes.map { .beforeStart(minutes: $0) }
            : allDayTimes.map { .onStartDay(at: $0) }
    }

    static func adapted(_ reminder: ItemReminder, usesTime: Bool) -> ItemReminder {
        switch (reminder, usesTime) {
        case (.onStartDay, true): .beforeStart(minutes: 10)
        case (.beforeStart, false): .onStartDay(at: ItemReminder.defaultAllDayTime)
        default: reminder
        }
    }
}

/// Mirrors reminder-carrying items into local notifications on this phone.
/// Identifiers embed the request fingerprint, so an edit replaces the old
/// notification instead of leaving a stale one behind.
@MainActor
final class MobileReminderScheduler {
    static let identifierPrefix = "jelly.reminder."
    /// iOS keeps at most 64 pending notifications per app.
    static let pendingLimit = 60

    private let center: UNUserNotificationCenter
    private var askedForPermission = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    static func identifier(for request: ReminderRequest) -> String {
        identifierPrefix + request.key + "." + String(request.fingerprint.prefix(16))
    }

    static func desired(in state: WorkspaceState, now: Date) -> [ReminderRequest] {
        ReminderPlanner.requests(in: state, now: now)
            .filter { $0.fireDate > now }
            .prefix(pendingLimit)
            .map { $0 }
    }

    func sync(state: WorkspaceState, now: Date = Date()) async {
        let desired = Self.desired(in: state, now: now)
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        let wanted = Dictionary(desired.map { (Self.identifier(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let stale = pending.filter { wanted[$0] == nil }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
        let missing = wanted.filter { !pending.contains($0.key) }
        guard !missing.isEmpty, await ensureAuthorized() else { return }
        for (identifier, request) in missing {
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.notes
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: request.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }

    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            guard !askedForPermission else { return false }
            askedForPermission = true
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }
}
