import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("InspirationFollowUpTests")
struct InspirationFollowUpTests {
    private let reviewDay = Task4Fixture.now.addingTimeInterval(3 * 86_400)

    @Test func reviewQueueBringsBackOldUntouchedInspirationsOnly() throws {
        var workspace = try Task4Fixture.workspace()
        let id = Task4Fixture.inspirationID
        #expect(InspirationReviewQueue.due(in: workspace, now: Task4Fixture.now).isEmpty)
        #expect(InspirationReviewQueue.due(in: workspace, now: reviewDay).map(\.id) == [id])

        workspace = try #require(try WorkspaceReducer.reduce(
            workspace,
            command: .reviewInspiration(id, at: reviewDay),
            now: reviewDay
        ).change).state
        #expect(workspace.inspirations[id]?.lastReviewedAt == reviewDay)
        #expect(InspirationReviewQueue.due(in: workspace, now: reviewDay.addingTimeInterval(86_400)).isEmpty)
        #expect(
            InspirationReviewQueue.due(in: workspace, now: reviewDay.addingTimeInterval(8 * 86_400)).map(\.id)
                == [id]
        )

        workspace.inspirations[id]?.lifecycle = .archived
        #expect(InspirationReviewQueue.due(in: workspace, now: reviewDay.addingTimeInterval(30 * 86_400)).isEmpty)
    }

    @Test func schedulingOnCalendarCreatesItemAndLeavesRawInspirationUntouched() throws {
        let workspace = try Task4Fixture.workspace()
        let id = Task4Fixture.inspirationID
        let item = try Task4Fixture.item(id: Task4Fixture.uuid(900), title: "给想法约个时间")
        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .scheduleInspiration(.init(inspirationID: id, target: .calendar(item))),
            now: reviewDay
        )
        let state = try #require(result.change).state
        #expect(state.calendar.items[item.id]?.title == "给想法约个时间")
        #expect(state.inspirations[id]?.scheduledItemIDs == [item.id])
        #expect(state.inspirations[id]?.rawText == workspace.inspirations[id]?.rawText)
        #expect(state.inspirations[id]?.lastReviewedAt == reviewDay)
        #expect(InspirationReviewQueue.due(in: state, now: reviewDay.addingTimeInterval(30 * 86_400)).isEmpty)

        let record = try #require(WorkspaceUndoReducer.record(before: workspace, after: state, label: "安排"))
        let undone = try WorkspaceUndoReducer.apply(
            record,
            direction: .undo,
            to: state,
            noteRevisionHighWatermarks: [:]
        ).candidate
        #expect(undone.calendar.items[item.id] == nil)
        #expect(undone.inspirations[id]?.scheduledItemIDs == [])
        #expect(undone.inspirations[id]?.lastReviewedAt == nil)
    }

    @Test func undatedListKeepsSourceAndSchedulingMovesItToCalendar() throws {
        let workspace = try Task4Fixture.workspace()
        let id = Task4Fixture.inspirationID
        let undated = UndatedItem(
            id: Task4Fixture.uuid(901),
            title: "以后再说的一件事",
            categoryID: Task4Fixture.uncategorizedID,
            sourceInspirationID: id,
            createdAt: reviewDay,
            updatedAt: reviewDay
        )
        var state = try #require(try WorkspaceReducer.reduce(
            workspace,
            command: .scheduleInspiration(.init(inspirationID: id, target: .undated(undated))),
            now: reviewDay
        ).change).state
        #expect(state.undatedItems[undated.id] == undated)
        #expect(InspirationReviewQueue.due(in: state, now: reviewDay.addingTimeInterval(30 * 86_400)).isEmpty)

        let item = try Task4Fixture.item(id: Task4Fixture.uuid(902), title: undated.title)
        state = try #require(try WorkspaceReducer.reduce(
            state,
            command: .scheduleUndatedItem(undated.id, item: item),
            now: reviewDay
        ).change).state
        #expect(state.undatedItems.isEmpty)
        #expect(state.calendar.items[item.id] != nil)
        #expect(state.inspirations[id]?.scheduledItemIDs == [item.id])
    }

    @Test func undatedItemsFollowCategoryDeletionAndRejectBlankTitles() throws {
        var workspace = try Task4Fixture.workspace()
        let undated = UndatedItem(
            id: Task4Fixture.uuid(903),
            title: "放进工作分类",
            categoryID: Task4Fixture.workCategoryID,
            createdAt: reviewDay,
            updatedAt: reviewDay
        )
        workspace = try #require(try WorkspaceReducer.reduce(
            workspace,
            command: .createUndatedItem(undated),
            now: reviewDay
        ).change).state
        let deleted = try #require(try WorkspaceReducer.reduce(
            workspace,
            command: .deleteCategory(Task4Fixture.workCategoryID),
            now: reviewDay
        ).change).state
        #expect(deleted.undatedItems[undated.id]?.categoryID == Task4Fixture.uncategorizedID)

        var blank = undated
        blank.title = "   "
        #expect(throws: WorkspaceReducerError.invalidUndatedItem) {
            try WorkspaceReducer.reduce(workspace, command: .updateUndatedItem(blank), now: reviewDay)
        }
    }

    @Test func expansionMustMatchCurrentTextAndDecisionsAreRecorded() throws {
        let workspace = try Task4Fixture.workspace()
        let id = Task4Fixture.inspirationID
        let inspiration = try #require(workspace.inspirations[id])
        let directions = [
            ExpansionDirection(id: Task4Fixture.uuid(910), text: "先找一个具体场景试一试"),
            ExpansionDirection(id: Task4Fixture.uuid(911), text: "问问身边的人怎么看")
        ]
        let expansion = InspirationExpansion(
            supplement: "这个想法的关键是先做一个最小版本。",
            directions: directions,
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
            modelIdentifier: "test",
            createdAt: reviewDay
        )
        var state = try #require(try WorkspaceReducer.reduce(
            workspace,
            command: .setInspirationExpansion(id, expansion),
            now: reviewDay
        ).change).state
        #expect(state.inspirations[id]?.rawText == inspiration.rawText)

        state = try #require(try WorkspaceReducer.reduce(
            state,
            command: .decideExpansionDirection(id, directionID: directions[1].id, decision: .adopted),
            now: reviewDay
        ).change).state
        #expect(state.inspirations[id]?.expansion?.adoptedDirections.map(\.text) == ["问问身边的人怎么看"])

        var stale = expansion
        stale.sourceChecksum = "old"
        #expect(try WorkspaceReducer.reduce(
            workspace,
            command: .setInspirationExpansion(id, stale),
            now: reviewDay
        ) == .noChange(.staleInspirationExpansion))

        var tooMany = expansion
        tooMany.directions = [directions[0]]
        #expect(throws: WorkspaceReducerError.invalidInspiration) {
            try WorkspaceReducer.reduce(workspace, command: .setInspirationExpansion(id, tooMany), now: reviewDay)
        }
    }

    @Test func perspectiveStoresUserAnswerNextToQuestions() throws {
        let workspace = try Task4Fixture.workspace()
        let id = Task4Fixture.inspirationID
        let perspective = InspirationPerspective(
            questions: ["你同意作者的核心判断吗？"],
            answer: "部分同意，但样本太小。",
            updatedAt: reviewDay
        )
        let state = try #require(try WorkspaceReducer.reduce(
            workspace,
            command: .setInspirationPerspective(id, perspective),
            now: reviewDay
        ).change).state
        #expect(state.inspirations[id]?.perspective?.hasAnswer == true)
    }

    @Test func reminderRoundTripsAndComputesFireDates() throws {
        let schedule = try CalendarSchedule(
            startDate: CalendarDate(year: 2026, month: 9, day: 30)!,
            endDate: CalendarDate(year: 2026, month: 9, day: 30)!,
            startTime: MinuteOfDay(hour: 15, minute: 0),
            endTime: MinuteOfDay(hour: 16, minute: 0)
        )
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let fire = try #require(ItemReminder.beforeStart(minutes: 10).fireDate(for: schedule, timeZone: zone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        #expect(calendar.dateComponents([.hour, .minute], from: fire) == DateComponents(hour: 14, minute: 50))

        let allDay = try CalendarSchedule(startDate: schedule.startDate, endDate: schedule.startDate, startTime: nil, endTime: nil)
        #expect(ItemReminder.beforeStart(minutes: 10).adapted(to: allDay) == .onStartDay(at: ItemReminder.defaultAllDayTime))
        #expect(ItemReminder.beforeStart(minutes: 10).fireDate(for: allDay, timeZone: zone) == nil)

        let item = try CalendarItem(
            id: Task4Fixture.uuid(920),
            kind: .task,
            title: "开会",
            categoryID: Task4Fixture.uncategorizedID,
            schedule: schedule,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            reminder: .beforeStart(minutes: 10),
            completedAt: nil,
            createdAt: Task4Fixture.now,
            updatedAt: Task4Fixture.now
        )
        let decoded = try JSONDecoder().decode(CalendarItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.reminder == .beforeStart(minutes: 10))

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        legacy.removeValue(forKey: "reminder")
        let legacyItem = try JSONDecoder().decode(
            CalendarItem.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(legacyItem.reminder == nil)
    }

    @Test func olderInspirationJSONWithoutFollowUpFieldsStillDecodes() throws {
        let workspace = try Task4Fixture.workspace()
        let inspiration = try #require(workspace.inspirations[Task4Fixture.inspirationID])
        let data = try JSONEncoder().encode(inspiration)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["scheduledItemIDs"] == nil)
        #expect(object["expansion"] == nil)
        let decoded = try JSONDecoder().decode(Inspiration.self, from: data)
        #expect(decoded == inspiration)
    }
}
