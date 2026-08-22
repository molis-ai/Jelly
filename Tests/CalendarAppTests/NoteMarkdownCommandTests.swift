import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("NoteMarkdownCommandTests")
struct NoteMarkdownCommandTests {
    @Test func supportedFileFormatsAreOnlyMarkdownAndHTMLForNow() {
        #expect(NoteFileFormat.allCases == [.markdown, .html])
        #expect(NoteFileFormat.detect(from: URL(fileURLWithPath: "/tmp/NOTE.MD")) == .markdown)
        #expect(NoteFileFormat.detect(from: URL(fileURLWithPath: "/tmp/note.html")) == .html)
        #expect(NoteFileFormat.detect(from: URL(fileURLWithPath: "/tmp/note.txt")) == nil)
    }

    @Test func htmlImportAndExportPreserveRichStructure() throws {
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = try NoteFileCommands.planImport(
            contents: "<h1>标题</h1><ul><li><input type=\"checkbox\" checked>完成</li></ul>",
            format: .html,
            fileName: "验收.html",
            mode: .append,
            checkedTaskCompletedAt: completedAt
        )
        #expect(plan.format == .html)
        #expect(plan.fileName == "验收.html")
        #expect(plan.result.document.blocks.map(\.kind) == [.heading1, .task])
        #expect(plan.result.document.blocks.last?.taskState?.completedAt == completedAt)

        let exported = try NoteFileCommands.export(
            plan.result.document,
            format: .html,
            title: "验收"
        )
        #expect(exported.contains("<h1>标题</h1>"))
        #expect(exported.contains("type=\"checkbox\""))
    }

    @Test func genericExportWriteReadbackIsExact() throws {
        let value = "<!doctype html><p>正文</p>"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-export-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: url) }
        try NoteFileCommands.writeExport(contents: value, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == value)
    }

    @Test func exportSourcePrefersTheMatchingLiveEditorSnapshot() throws {
        let noteID = NoteID()
        let editSessionID = UUID()
        let persisted = BlockDocument(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain("旧正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let live = BlockDocument(blocks: [
            .init(
                id: BlockID(),
                kind: .bullet,
                inlineContent: .plain("实时正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])

        let selected = NoteMarkdownExportSource.document(
            persistedNoteID: noteID,
            persistedDocument: persisted,
            editorIdentity: .init(noteID: noteID, editSessionID: editSessionID),
            liveSnapshot: .init(
                noteID: noteID,
                editSessionID: editSessionID,
                document: live
            )
        )

        #expect(selected == live)
        #expect(try NoteMarkdownCommands.exportMarkdown(from: selected).contains("- 实时正文"))
    }

    @Test func exportSourcePrefersRebuiltSameNoteLiveSnapshotWithDifferentEditSessionID() {
        let noteID = NoteID()
        let persisted = BlockDocument(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain("已保存正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let rebuiltLive = BlockDocument(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain("重建后未保存正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])

        let selected = NoteMarkdownExportSource.document(
            persistedNoteID: noteID,
            persistedDocument: persisted,
            editorIdentity: .init(noteID: noteID, editSessionID: UUID()),
            liveSnapshot: .init(
                noteID: noteID,
                editSessionID: UUID(),
                document: rebuiltLive
            )
        )

        #expect(selected == rebuiltLive)
    }

    @Test func exportSourceRejectsADifferentNoteLiveSnapshot() {
        let persistedNoteID = NoteID()
        let persisted = BlockDocument(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain("已保存正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let otherNote = BlockDocument(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain("另一篇笔记正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])

        let selected = NoteMarkdownExportSource.document(
            persistedNoteID: persistedNoteID,
            persistedDocument: persisted,
            editorIdentity: .init(noteID: persistedNoteID, editSessionID: UUID()),
            liveSnapshot: .init(
                noteID: NoteID(),
                editSessionID: UUID(),
                document: otherNote
            )
        )

        #expect(selected == persisted)
    }

    @Test func importPlanRejectsEmptyMarkdownDocument() throws {
        #expect(throws: NoteMarkdownCommandError.emptyImport) {
            _ = try NoteMarkdownCommands.planImport(
                markdown: "\n\n",
                mode: .replace,
                checkedTaskCompletedAt: Date(timeIntervalSince1970: 1)
            )
        }
    }

    @Test func importPlanPreservesCheckedTaskCompletion() throws {
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = try NoteMarkdownCommands.planImport(
            markdown: "- [x] 已完成任务\n",
            mode: .append,
            checkedTaskCompletedAt: completedAt
        )
        #expect(plan.mode == .append)
        let task = try #require(plan.result.document.blocks.first)
        #expect(task.kind == .task)
        #expect(task.taskState?.completedAt == completedAt)
    }

    @Test func exportWriteReadbackIsExact() throws {
        let document = BlockDocument(blocks: [
            .init(id: BlockID(), kind: .paragraph, inlineContent: .plain("导出正文"), taskState: nil, indentLevel: 0)
        ])
        let markdown = try NoteMarkdownCommands.exportMarkdown(from: document)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-export-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try NoteMarkdownCommands.writeExport(markdown: markdown, to: url)
        let readback = try String(contentsOf: url, encoding: .utf8)
        #expect(readback == markdown)
    }

    @Test func documentImportCommandReplacesAndAppendsAtomically() throws {
        let first = DocumentBlock(
            id: BlockID(), kind: .paragraph, inlineContent: .plain("原有"), taskState: nil, indentLevel: 0
        )
        let imported = DocumentBlock(
            id: BlockID(), kind: .paragraph, inlineContent: .plain("导入"), taskState: nil, indentLevel: 0
        )
        let base = BlockDocument(blocks: [first])
        let selection = BlockEditorSelection.text(
            anchor: .init(blockID: first.id, graphemeOffset: 0),
            focus: .init(blockID: first.id, graphemeOffset: 0),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        let replaced = try BlockInputReducer.reduce(
            base,
            selection: selection,
            command: .applyDocumentBlocks(blocks: [imported], mode: .replace),
            environment: .init(isComposingText: false, idSource: .random)
        )
        #expect(replaced.mutation == .document)
        #expect(replaced.effect == .handled)
        if case let .atomic(action) = replaced.undo {
            #expect(action == .documentIngest)
        } else {
            Issue.record("expected atomic documentIngest undo")
        }
        #expect(replaced.document.blocks.map(\.id) == [imported.id])

        let appended = try BlockInputReducer.reduce(
            base,
            selection: selection,
            command: .applyDocumentBlocks(blocks: [imported], mode: .append),
            environment: .init(isComposingText: false, idSource: .random)
        )
        #expect(appended.document.blocks.map(\.id) == [first.id, imported.id])
    }

    @Test func documentIngestRejectsDuplicateIDsOnAppend() throws {
        let shared = BlockID()
        let existing = DocumentBlock(
            id: shared, kind: .paragraph, inlineContent: .plain("A"), taskState: nil, indentLevel: 0
        )
        let collision = DocumentBlock(
            id: shared, kind: .paragraph, inlineContent: .plain("B"), taskState: nil, indentLevel: 0
        )
        let selection = BlockEditorSelection.text(
            anchor: .init(blockID: shared, graphemeOffset: 0),
            focus: .init(blockID: shared, graphemeOffset: 0),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        #expect(throws: BlockInputError.duplicateBlockID(shared)) {
            _ = try BlockInputReducer.reduce(
                BlockDocument(blocks: [existing]),
                selection: selection,
                command: .applyDocumentBlocks(blocks: [collision], mode: .append),
                environment: .init(isComposingText: false, idSource: .random)
            )
        }
    }
}
