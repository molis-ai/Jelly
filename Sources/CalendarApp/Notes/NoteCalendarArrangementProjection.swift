import CalendarDomain
import Foundation
import WorkspaceDomain

struct NoteCalendarArrangement: Identifiable, Equatable {
    let target: WorkspaceDeepLinkTarget
    let title: String
    let subtitle: String
    let isCompleted: Bool

    var id: WorkspaceDeepLinkTarget { target }
}

enum NoteCalendarArrangementProjection {
    static func make(noteID: NoteID, state: WorkspaceState) -> [NoteCalendarArrangement] {
        var rowsByTarget: [WorkspaceDeepLinkTarget: NoteCalendarArrangement] = [:]

        for (owner, relation) in state.calendarNoteRelations.baselines
        where relation.contains(noteID) {
            switch owner {
            case let .item(itemID):
                if let item = state.calendar.items[itemID] {
                    rowsByTarget[.calendarItem(itemID)] = .init(
                        target: .calendarItem(itemID),
                        title: item.title,
                        subtitle: dateSubtitle(item.schedule),
                        isCompleted: item.completedAt != nil
                    )
                }
            case let .series(seriesID):
                if let series = state.calendar.recurrence.series[seriesID] {
                    rowsByTarget[.calendarSeries(seriesID)] = .init(
                        target: .calendarSeries(seriesID),
                        title: series.title,
                        subtitle: seriesSubtitle(series),
                        isCompleted: false
                    )
                }
            }
        }

        for link in state.taskBlockLinks where link.noteID == noteID {
            guard let item = state.calendar.items[link.calendarItemID] else { continue }
            rowsByTarget[.calendarItem(item.id)] = .init(
                target: .calendarItem(item.id),
                title: item.title,
                subtitle: dateSubtitle(item.schedule),
                isCompleted: item.completedAt != nil
            )
        }

        for (key, _) in state.calendarNoteRelations.occurrenceOverrides {
            let baseline = state.calendarNoteRelations.baselines[.series(key.seriesID)]
            if baseline?.contains(noteID) == true {
                continue
            }
            guard let resolved = try? CalendarNoteRelationResolver.resolve(
                .occurrence(key),
                calendar: state.calendar,
                relations: state.calendarNoteRelations
            ), resolved.isClickable, resolved.noteSet.contains(noteID),
            let occurrence = CalendarDeepLinkTargetResolver.occurrence(for: key, calendar: state.calendar)
            else { continue }
            rowsByTarget[.calendarOccurrence(key)] = .init(
                target: .calendarOccurrence(key),
                title: occurrence.title,
                subtitle: "单次安排 · \(dateSubtitle(occurrence.schedule))",
                isCompleted: occurrence.completedAt != nil
            )
        }

        return rowsByTarget.values.sorted {
            if $0.subtitle != $1.subtitle { return $0.subtitle < $1.subtitle }
            if $0.title != $1.title { return $0.title < $1.title }
            return String(describing: $0.target) < String(describing: $1.target)
        }
    }

    private static func dateSubtitle(_ schedule: CalendarSchedule) -> String {
        "\(schedule.startDate.month) 月 \(schedule.startDate.day) 日\(schedule.startTime == nil ? " · 全天" : "")"
    }

    private static func seriesSubtitle(_ series: WeeklySeries) -> String {
        let weekdays = series.weekdays.sorted { $0.rawValue < $1.rawValue }.map(weekdayLabel).joined(separator: "、")
        return "重复事项 · 每周\(weekdays)"
    }

    private static func weekdayLabel(_ weekday: Weekday) -> String {
        switch weekday {
        case .monday: "一"
        case .tuesday: "二"
        case .wednesday: "三"
        case .thursday: "四"
        case .friday: "五"
        case .saturday: "六"
        case .sunday: "日"
        }
    }
}

private extension CalendarNoteSet {
    func contains(_ noteID: NoteID) -> Bool {
        primaryNoteID == noteID || referenceNoteIDs.contains(noteID)
    }
}
