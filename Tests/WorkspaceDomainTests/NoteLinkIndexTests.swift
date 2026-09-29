import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("NoteLinkIndexTests")
struct NoteLinkIndexTests {
    private let category = UUID()

    private func note(
        _ title: String,
        blocks: [InlineContent] = [],
        updated: TimeInterval = 0,
        archived: Bool = false
    ) -> Note {
        Note(
            id: NoteID(),
            title: title,
            document: BlockDocument(blocks: blocks.map {
                DocumentBlock(id: BlockID(), kind: .paragraph, inlineContent: $0, taskState: nil, indentLevel: 0)
            }),
            categoryID: category,
            archivedAt: archived ? Date(timeIntervalSince1970: updated) : nil,
            revision: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private func linking(_ before: String, to target: Note, _ after: String = "") -> InlineContent {
        InlineContent(spans: [
            InlineSpan(text: before),
            InlineSpan(text: target.title, linkURL: NoteLinkURL.url(for: target.id)),
            InlineSpan(text: after)
        ])
    }

    private func state(_ notes: [Note]) -> WorkspaceState {
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        for note in notes { state.notes[note.id] = note }
        return state
    }

    @Test func urlRoundTripsAndIgnoresOtherLinks() {
        let id = NoteID()
        let url = NoteLinkURL.url(for: id)
        #expect(url.absoluteString == "jelly://note/\(id.rawValue.uuidString)")
        #expect(NoteLinkURL.noteID(from: url) == id)
        #expect(NoteLinkURL.noteID(from: URL(string: "JELLY://NOTE/\(id.rawValue.uuidString)")) == id)
        #expect(NoteLinkURL.noteID(from: URL(string: "https://note/\(id.rawValue.uuidString)")) == nil)
        #expect(NoteLinkURL.noteID(from: URL(string: "jelly://item/\(id.rawValue.uuidString)")) == nil)
        #expect(NoteLinkURL.noteID(from: URL(string: "jelly://note/not-a-uuid")) == nil)
        #expect(NoteLinkURL.noteID(from: nil) == nil)
    }

    @Test func backlinksComeFromOtherNotesNewestFirstWithTheWholeBlockAsExcerpt() {
        let target = note("深度工作")
        let older = note("读书笔记", updated: 10)
        var olderLinking = older
        olderLinking.document = BlockDocument(blocks: [
            DocumentBlock(id: BlockID(), kind: .paragraph, inlineContent: linking("参考 ", to: target, " 第三章"), taskState: nil, indentLevel: 0),
            DocumentBlock(id: BlockID(), kind: .paragraph, inlineContent: .plain("无关的一段"), taskState: nil, indentLevel: 0)
        ])
        let newer = note("周计划", blocks: [linking("", to: target)], updated: 20, archived: true)
        let selfLink = note("自引用")
        var targetWithSelfLink = target
        targetWithSelfLink.document = BlockDocument(blocks: [
            DocumentBlock(id: BlockID(), kind: .paragraph, inlineContent: linking("见 ", to: target), taskState: nil, indentLevel: 0)
        ])
        let workspace = state([targetWithSelfLink, olderLinking, newer, selfLink])

        let backlinks = NoteLinkIndex.backlinks(to: target.id, in: workspace)
        #expect(backlinks.map(\.sourceNoteID) == [newer.id, older.id])
        #expect(backlinks.map(\.sourceIsArchived) == [true, false])
        #expect(backlinks.last?.excerpt == "参考 深度工作 第三章")
        #expect(NoteLinkIndex.backlinks(to: selfLink.id, in: workspace).isEmpty)
        #expect(NoteLinkIndex.outgoingNoteIDs(in: olderLinking.document) == [target.id])
    }

    @Test func longBlocksAreTrimmedInTheExcerpt() {
        let target = note("目标")
        let source = note("长文", blocks: [linking(String(repeating: "字", count: 200), to: target)])
        let excerpt = NoteLinkIndex.backlinks(to: target.id, in: state([target, source])).first?.excerpt
        #expect(excerpt?.count == NoteLinkIndex.excerptLimit)
        #expect(excerpt?.hasSuffix("…") == true)
    }

    @Test func candidatesMatchTitlesAndPutArchivedNotesLast() {
        let current = note("当前笔记", updated: 50)
        let archived = note("工作复盘（旧）", updated: 40, archived: true)
        let recent = note("工作周报", updated: 30)
        let old = note("工作方法", updated: 10)
        let other = note("旅行清单", updated: 45)
        let workspace = state([current, archived, recent, old, other])

        #expect(NoteLinkIndex.candidates(matching: "工作", in: workspace, excluding: current.id).map(\.id)
            == [recent.id, old.id, archived.id])
        #expect(NoteLinkIndex.candidates(matching: "", in: workspace, excluding: current.id, limit: 2).map(\.id)
            == [other.id, recent.id])
        #expect(NoteLinkIndex.candidates(matching: "当前", in: workspace, excluding: current.id).isEmpty)
    }

    @Test func noteLinksSurviveMarkdownExportAndImport() throws {
        let target = note("深度工作")
        let document = BlockDocument(blocks: [
            DocumentBlock(id: BlockID(), kind: .paragraph, inlineContent: linking("参考 ", to: target, " 吧"), taskState: nil, indentLevel: 0)
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        #expect(markdown.contains("[深度工作](<jelly://note/\(target.id.rawValue.uuidString)>)"))
        let imported = try BlockMarkdownCodec.importMarkdown(markdown, checkedTaskCompletedAt: .distantPast)
        #expect(NoteLinkIndex.outgoingNoteIDs(in: imported.document) == [target.id])
    }
}
