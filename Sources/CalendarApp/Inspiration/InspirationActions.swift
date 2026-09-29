import CalendarDomain
import Foundation
import WorkspaceDomain

/// Where 回顾 or the detail page sends a thought that should become a to-do.
enum InspirationScheduleChoice: Equatable, Sendable {
    case today
    case tomorrow
    case day(CalendarDate)
    case undated

    var confirmation: String {
        switch self {
        case .today: "已安排到今天"
        case .tomorrow: "已安排到明天"
        case let .day(date): "已安排到 \(date.month) 月 \(date.day) 日"
        case .undated: "已放进无日期清单"
        }
    }
}

enum InspirationActionFactory {
    static let titleLimit = 60

    /// The to-do title: an explicitly chosen text (e.g. an adopted direction),
    /// else the link title, else the first line of the thought.
    static func title(for inspiration: Inspiration, preferred: String? = nil) -> String {
        let candidates = [
            preferred,
            inspiration.resolvedMetadata?.title,
            inspiration.rawText.flatMap(firstLine),
            inspiration.rawFile?.displayName,
            inspiration.rawURL?.host
        ]
        let title = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "处理一条灵感"
        return title.count <= titleLimit ? title : String(title.prefix(titleLimit - 1)) + "…"
    }

    /// Keeps the original words with the to-do so it still makes sense later.
    static func notes(for inspiration: Inspiration) -> String {
        var lines: [String] = []
        if let text = inspiration.rawText, !text.isEmpty { lines.append(text) }
        if let url = inspiration.rawURL { lines.append(url.absoluteString) }
        if let file = inspiration.rawFile { lines.append("材料文件：\(file.displayName)") }
        if let expansion = inspiration.expansion, !expansion.adoptedDirections.isEmpty {
            lines.append("")
            lines.append(contentsOf: expansion.adoptedDirections.map { "- \($0.text)" })
        }
        return lines.joined(separator: "\n")
    }

    static func date(for choice: InspirationScheduleChoice, today: CalendarDate) -> CalendarDate? {
        switch choice {
        case .today: today
        case .tomorrow: today.addingDays(1)
        case let .day(date): date
        case .undated: nil
        }
    }

    static func target(
        for inspiration: Inspiration,
        choice: InspirationScheduleChoice,
        preferredTitle: String? = nil,
        today: CalendarDate,
        now: Date,
        timeZone: TimeZone = .current
    ) throws -> InspirationActionTarget {
        let title = title(for: inspiration, preferred: preferredTitle)
        let notes = notes(for: inspiration)
        guard let day = date(for: choice, today: today) else {
            return .undated(UndatedItem(
                title: title,
                notes: notes,
                categoryID: inspiration.categoryID,
                sourceInspirationID: inspiration.id,
                createdAt: now,
                updatedAt: now
            ))
        }
        return .calendar(try CalendarItem(
            id: UUID(),
            kind: .unifiedTODO,
            title: title,
            categoryID: inspiration.categoryID,
            schedule: CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            creationTimeZoneIdentifier: timeZone.identifier,
            notes: notes,
            completedAt: nil,
            createdAt: now,
            updatedAt: now
        ))
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").map(String.init).first {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

extension CalendarDate {
    static func today(in timeZone: TimeZone = .current, now: Date = Date()) -> CalendarDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return CalendarDate(year: parts.year!, month: parts.month!, day: parts.day!)!
    }
}
