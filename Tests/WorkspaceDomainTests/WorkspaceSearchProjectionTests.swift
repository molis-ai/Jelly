import Foundation
import Testing
@testable import WorkspaceDomain

@Suite("WorkspaceSearchProjectionTests")
struct WorkspaceSearchProjectionTests {
    @Test func buildsChineseTitleAndBodyRecordsAndFiltersArchive() throws {
        let category = UUID()
        let noteID = NoteID()
        let note = Note(
            id: noteID,
            title: "中文标题",
            document: .init(blocks: [
                .init(id: BlockID(), kind: .paragraph, inlineContent: .plain("正文内容"), taskState: nil, indentLevel: 0)
            ]),
            categoryID: category,
            archivedAt: nil,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let archivedNote = Note(
            id: NoteID(),
            title: "已归档",
            document: .empty(),
            categoryID: category,
            archivedAt: .distantPast,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let state = WorkspaceState(
            revision: 3,
            calendar: .empty(uncategorizedID: category, now: .distantPast),
            notes: [note.id: note, archivedNote.id: archivedNote],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: [],
            materialDigests: [:]
        )
        let projection = WorkspaceSearchProjection.build(from: state)
        #expect(projection.workspaceRevision == 3)
        let hits = projection.search(query: "中文", kind: .note, includeArchived: false)
        #expect(hits.count == 1)
        #expect(hits[0].objectID == .note(note.id))
        let archivedHits = projection.search(query: "归档", kind: .note, includeArchived: true)
        #expect(archivedHits.count == 1)
        let hidden = projection.search(query: "归档", kind: .note, includeArchived: false)
        #expect(hidden.isEmpty)
    }
}
