import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

/// Real JSON persistence gates for plan apply.
///
/// These two guarantees are independent:
/// 1. A fresh `WorkspaceStore` loaded from the same JSON file after apply still
///    contains the plan's task blocks, completion descriptions, calendar items,
///    relations, and links. Restart does not restore a session undo stack.
/// 2. Undoing on the original in-memory store persists the reverse record, so a
///    later fresh load sees the plan objects gone and the source note plus
///    pre-existing objects still present.
@Suite("DecompositionEndToEndTests")
@MainActor
struct DecompositionEndToEndTests {
    @Test func jsonStorePersistsPlanAcrossRestartAndSameSessionUndoRemovesOnlyPlanObjects() async throws {
        let directory = try EndToEndTempDirectory()
        defer { directory.remove() }
        let urls = EndToEndWorkspaceURLs(directory: directory)

        let firstStore = try await loadJSONStore(urls)
        let existingItemID = UUID(uuidString: "00000000-0000-0000-0000-000000000751")!
        let existingItem = try CalendarItem(
            id: existingItemID,
            kind: .event,
            title: "已有例会",
            categoryID: firstStore.calendarState.uncategorizedID,
            schedule: try CalendarSchedule(
                startDate: EndToEndFixtures.day,
                endDate: EndToEndFixtures.day,
                startTime: nil,
                endTime: nil
            ),
            creationTimeZoneIdentifier: EndToEndFixtures.shanghai.identifier,
            completedAt: nil,
            createdAt: EndToEndFixtures.now,
            updatedAt: EndToEndFixtures.now
        )
        guard case .committed = try await firstStore.sendWorkspace(
            .calendar(.createItem(existingItem)),
            undoLabel: "已有例会"
        ) else {
            Issue.record("pre-existing calendar item must commit")
            return
        }

        let source = try await createChineseSourceNote(in: firstStore)
        let payload = try makeRealPayload(
            source: source,
            calendarState: firstStore.calendarState,
            workspaceRevision: firstStore.state.revision
        )
        guard case .committed = try await firstStore.sendWorkspace(
            .applyDecompositionPlan(payload),
            undoLabel: "拆开并安排"
        ) else {
            Issue.record("plan apply must commit before restart and undo gates")
            return
        }
        #expect(planObjectsExist(firstStore.state, payload: payload, sourceNoteID: source.id))
        #expect(firstStore.state.calendar.items[existingItemID] != nil)

        // Guarantee 1: a restarted store loads persisted plan objects. It has no
        // undo stack, so this store is not asked to undo.
        let restarted = try await loadJSONStore(urls)
        #expect(planObjectsExist(restarted.state, payload: payload, sourceNoteID: source.id))
        #expect(restarted.state.calendar.items[existingItemID]?.title == "已有例会")
        #expect(restarted.state.notes[source.id]?.title == "周末物业上门")
        #expect(sourceParagraphRemains(in: restarted.state, noteID: source.id))
        #expect(restarted.canUndo == false)

        // Guarantee 2: undo is session memory on the original store; after that
        // undo is saved, a third fresh load must not contain this plan.
        guard case .committed = try await firstStore.undo() else {
            Issue.record("same-session undo of the plan must commit")
            return
        }
        #expect(planObjectsAreAbsent(firstStore.state, payload: payload, sourceNoteID: source.id))
        #expect(firstStore.state.calendar.items[existingItemID] != nil)

        let afterUndo = try await loadJSONStore(urls)
        #expect(planObjectsAreAbsent(afterUndo.state, payload: payload, sourceNoteID: source.id))
        #expect(afterUndo.state.notes[source.id]?.title == "周末物业上门")
        #expect(sourceParagraphRemains(in: afterUndo.state, noteID: source.id))
        #expect(afterUndo.state.calendar.items[existingItemID]?.title == "已有例会")
    }
}

@MainActor
private func loadJSONStore(_ urls: EndToEndWorkspaceURLs) async throws -> WorkspaceStore {
    let seed = WorkspaceState.empty(
        calendar: CalendarState.empty(
            uncategorizedID: EndToEndFixtures.categoryID,
            now: EndToEndFixtures.now
        )
    )
    let repository = JSONWorkspaceRepository(
        documentURL: urls.document,
        seed: { seed },
        snapshotDirectoryURL: urls.snapshots,
        recoveryManifestURL: urls.manifest
    )
    let store = WorkspaceStore(
        initialState: seed,
        repository: repository,
        journal: DraftJournalRepository(fileURL: urls.journal)
    )
    await store.load()
    return store
}

@MainActor
private func createChineseSourceNote(in store: WorkspaceStore) async throws -> Note {
    let sourceBlockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000752")!)
    var note = Note.empty(
        id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000753")!),
        categoryID: store.calendarState.uncategorizedID,
        now: EndToEndFixtures.now
    )
    note.title = "周末物业上门"
    note.document = .init(blocks: [
        .init(
            id: sourceBlockID,
            kind: .paragraph,
            inlineContent: .plain(EndToEndFixtures.sourceBody),
            taskState: nil,
            indentLevel: 0
        )
    ])
    guard case .committed = try await store.sendWorkspace(
        .createNote(.init(note: note)),
        undoLabel: "来源笔记"
    ) else {
        Issue.record("source note must commit")
        throw EndToEndFixtureError.sourceNoteNotCommitted
    }
    return try #require(store.state.notes[note.id])
}

@MainActor
private func makeRealPayload(
    source: Note,
    calendarState: CalendarState,
    workspaceRevision: Int64
) throws -> ApplyDecompositionPlanPayload {
    let snapshot = try DecompositionSourceCapture.capture(
        note: source,
        workspaceRevision: workspaceRevision,
        selection: .text(
            anchor: .init(blockID: source.document.blocks[0].id, graphemeOffset: 0),
            focus: .init(blockID: source.document.blocks[0].id, graphemeOffset: 0),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
    )
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000754")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000755")!
    var candidates = [
        CandidateAction(
            id: firstID,
            title: "给物业打电话",
            completionDescription: "拿到明确上门时间",
            estimatedDuration: .minutes30,
            selectedForCreation: true,
            selectedForCalendar: true,
            titleLockedByUser: false,
            completionLockedByUser: false,
            sourceCandidateID: nil,
            proposal: nil
        ),
        CandidateAction(
            id: secondID,
            title: "把约定写进笔记",
            completionDescription: "日历里能看见约定",
            estimatedDuration: .minutes15,
            selectedForCreation: true,
            selectedForCalendar: false,
            titleLockedByUser: false,
            completionLockedByUser: false,
            sourceCandidateID: nil,
            proposal: nil
        )
    ]
    let proposals = CalendarProposalEngine.propose(
        for: candidates,
        calendarState: calendarState,
        now: EndToEndFixtures.now,
        timeZone: EndToEndFixtures.shanghai
    )
    for index in candidates.indices {
        candidates[index].proposal = proposals[candidates[index].id]
    }
    #expect(candidates[0].proposal != nil)

    return try DecompositionPlanBuilder.makePayload(
        snapshot: snapshot,
        candidates: candidates,
        note: source,
        workspaceRevision: workspaceRevision,
        now: EndToEndFixtures.now,
        ids: DecompositionPlanIDs(
            blockIDs: [
                BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000756")!),
                BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000757")!)
            ],
            calendarItemIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000758")!]
        ),
        timeZone: EndToEndFixtures.shanghai
    )
}

private func planObjectsExist(
    _ state: WorkspaceState,
    payload: ApplyDecompositionPlanPayload,
    sourceNoteID: NoteID
) -> Bool {
    guard let note = state.notes[sourceNoteID] else { return false }
    guard sourceParagraphRemains(in: state, noteID: sourceNoteID) else { return false }
    let tasks = note.document.blocks.filter { $0.kind == .task }
    guard tasks.map(\.id) == payload.taskBlocks.map(\.id) else { return false }
    guard tasks.map(blockText) == ["给物业打电话", "把约定写进笔记"] else { return false }
    guard tasks.map({ $0.taskState?.completionDescription }) == ["拿到明确上门时间", "日历里能看见约定"] else {
        return false
    }
    guard payload.calendarItems.allSatisfy({ state.calendar.items[$0.id] != nil }) else { return false }
    guard payload.calendarItems.allSatisfy({ item in
        state.calendar.items[item.id]?.title == "给物业打电话"
            && state.calendarNoteRelations.baselines[.item(item.id)]?.primaryNoteID == sourceNoteID
    }) else { return false }
    let expectedLinks = Set(payload.links.map { "\($0.noteID.rawValue.uuidString):\($0.blockID.rawValue.uuidString):\($0.calendarItemID.uuidString)" })
    let actualLinks = Set(state.taskBlockLinks.map { "\($0.noteID.rawValue.uuidString):\($0.blockID.rawValue.uuidString):\($0.calendarItemID.uuidString)" })
    return expectedLinks.isSubset(of: actualLinks)
}

private func planObjectsAreAbsent(
    _ state: WorkspaceState,
    payload: ApplyDecompositionPlanPayload,
    sourceNoteID: NoteID
) -> Bool {
    guard let note = state.notes[sourceNoteID] else { return false }
    let taskIDs = Set(payload.taskBlocks.map(\.id))
    guard note.document.blocks.allSatisfy({ !taskIDs.contains($0.id) }) else { return false }
    guard sourceParagraphRemains(in: state, noteID: sourceNoteID) else { return false }
    guard note.document.blocks.count == 1 else { return false }
    guard payload.calendarItems.allSatisfy({ state.calendar.items[$0.id] == nil }) else { return false }
    guard payload.links.allSatisfy({ link in
        !state.taskBlockLinks.contains(where: {
            $0.noteID == link.noteID
                && $0.blockID == link.blockID
                && $0.calendarItemID == link.calendarItemID
        })
    }) else { return false }
    return payload.calendarItems.allSatisfy {
        state.calendarNoteRelations.baselines[.item($0.id)] == nil
    }
}

private func sourceParagraphRemains(in state: WorkspaceState, noteID: NoteID) -> Bool {
    guard let first = state.notes[noteID]?.document.blocks.first else { return false }
    return first.kind == .paragraph && blockText(first) == EndToEndFixtures.sourceBody
}

private func blockText(_ block: DocumentBlock) -> String {
    block.inlineContent.spans.map(\.text).joined()
}

private enum EndToEndFixtures {
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000750")!
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static let now = Date(timeIntervalSince1970: 1_787_356_800)
    static let day = CalendarDate(year: 2026, month: 8, day: 22)!
    static let sourceBody = "这周末要给物业打电话，确认上门检修的具体时间"
}

private enum EndToEndFixtureError: Error {
    case sourceNoteNotCommitted
}

private struct EndToEndWorkspaceURLs {
    let document: URL
    let snapshots: URL
    let manifest: URL
    let journal: URL

    init(directory: EndToEndTempDirectory) {
        document = directory.file("calendar-v1.json")
        snapshots = directory.file("snapshots")
        manifest = directory.file("recovery-manifest.json")
        journal = directory.file("draft-journal.json")
    }
}

private final class EndToEndTempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-decomposition-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
