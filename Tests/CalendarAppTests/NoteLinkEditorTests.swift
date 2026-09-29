import AppKit
import CalendarPersistence
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("NoteLinkEditorTests")
@MainActor
struct NoteLinkEditorTests {
    private let plain = BlockTypingAttributes(marks: [], linkURL: nil)
    private let deepWork = NoteLinkCandidate(id: NoteID(), title: "深度工作", isArchived: false)
    private let weekly = NoteLinkCandidate(id: NoteID(), title: "工作周报", isArchived: true)

    private func session(
        _ text: String = "",
        kind: BlockKind = .paragraph,
        opened: @escaping (NoteID) -> Void = { _ in },
        created: ((String) async -> NoteID?)? = nil
    ) -> (BlockEditorSession, BlockID) {
        let id = BlockID()
        let document = BlockDocument(blocks: [.init(id: id, kind: kind, inlineContent: .plain(text), taskState: nil, indentLevel: 0)])
        let caret = BlockTextPosition(blockID: id, graphemeOffset: text.count)
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: document,
            initialSelection: .text(anchor: caret, focus: caret, preferredColumn: nil, typingAttributes: plain),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let all = [deepWork, weekly]
        session.noteLinkProvider = NoteLinkProvider(
            candidates: { query in all.filter { query.isEmpty || $0.title.contains(query) } },
            open: opened,
            create: created
        )
        return (session, id)
    }

    private func spans(_ session: BlockEditorSession) -> [InlineSpan] {
        session.document.blocks[0].inlineContent.spans
    }

    @Test func typingDoubleBracketOffersMatchingNotesAndInsertsALinkFollowedByPlainText() throws {
        let (session, id) = session("参考 ")
        _ = try session.dispatch(.insertText("[["))
        #expect(session.noteLinkMenuState?.options.count == 2)
        _ = try session.dispatch(.insertText("深度"))
        let state = try #require(session.noteLinkMenuState)
        #expect(state.blockID == id)
        #expect(state.query == "深度")
        #expect(state.queryRange == 3..<7)
        #expect(state.options == [.existing(deepWork)])

        session.chooseNoteLinkOption(state.options[0])
        #expect(session.noteLinkMenuState == nil)
        #expect(spans(session).map(\.text).joined() == "参考 深度工作 ")
        let link = try #require(spans(session).first { $0.linkURL != nil })
        #expect(link.text == "深度工作")
        #expect(NoteLinkURL.noteID(from: link.linkURL) == deepWork.id)

        _ = try session.dispatch(.insertText("第三章"))
        #expect(spans(session).map(\.text).joined() == "参考 深度工作 第三章")
        #expect(spans(session).filter { $0.linkURL != nil }.map(\.text) == ["深度工作"])
        #expect(session.noteLinkMenuState == nil)
    }

    @Test func chineseBracketsOpenThePickerToo() throws {
        let (session, _) = session()
        _ = try session.dispatch(.insertText("【【周报"))
        #expect(session.noteLinkMenuState?.query == "周报")
        #expect(session.noteLinkMenuState?.options.first == .existing(weekly))
    }

    @Test func exactTitleMatchHidesTheCreateRow() throws {
        let (session, _) = session(created: { _ in NoteID() })
        _ = try session.dispatch(.insertText("[[深度工作"))
        #expect(session.noteLinkMenuState?.options == [.existing(deepWork)])
    }

    @Test func noCreateRowWithoutACreator() throws {
        let (session, _) = session()
        _ = try session.dispatch(.insertText("[[没有这篇"))
        #expect(session.noteLinkMenuState?.options == [])
    }

    @Test func closingBracketsNewlinesAndCodeBlocksKeepThePickerClosed() throws {
        let (closed, _) = session()
        _ = try closed.dispatch(.insertText("[[深度]]"))
        #expect(closed.noteLinkMenuState == nil)

        let (code, _) = session(kind: .code)
        _ = try code.dispatch(.insertText("a[[0]"))
        #expect(code.noteLinkMenuState == nil)
    }

    @Test func escapeDismissesUntilANewOpenerIsTyped() throws {
        let (session, _) = session()
        _ = try session.dispatch(.insertText("[[深"))
        #expect(session.handleNoteLinkSelector(#selector(NSResponder.cancelOperation(_:))))
        #expect(session.noteLinkMenuState == nil)
        _ = try session.dispatch(.insertText("度"))
        #expect(session.noteLinkMenuState == nil)
        _ = try session.dispatch(.insertText(" [["))
        #expect(session.noteLinkMenuState?.query == "")
    }

    @Test func arrowKeysAndReturnPickFromTheList() throws {
        let (session, _) = session()
        _ = try session.dispatch(.insertText("[[工作"))
        #expect(session.noteLinkMenuState?.options.map(\.id) == [deepWork.id.rawValue.uuidString, weekly.id.rawValue.uuidString])
        #expect(session.handleNoteLinkSelector(#selector(NSResponder.moveDown(_:))))
        #expect(session.handleNoteLinkSelector(#selector(NSResponder.moveDown(_:))))
        #expect(session.noteLinkMenuState?.selectedIndex == 1)
        #expect(session.handleNoteLinkSelector(#selector(NSResponder.insertNewline(_:))))
        #expect(spans(session).first { $0.linkURL != nil }?.text == "工作周报")
        #expect(session.handleNoteLinkSelector(#selector(NSResponder.insertNewline(_:))) == false)
    }

    @Test func aLinkAlreadyInTheBlockDoesNotReopenThePicker() throws {
        let (session, _) = session()
        _ = try session.dispatch(.insertText("[[深"))
        session.chooseNoteLinkOption(.existing(deepWork))
        _ = try session.dispatch(.insertText("和"))
        #expect(session.noteLinkMenuState == nil)
    }

    @Test func creatingANewNoteLinksToIt() async throws {
        let createdID = NoteID()
        var requestedTitle: String?
        let (session, _) = session(created: { title in
            requestedTitle = title
            return createdID
        })
        _ = try session.dispatch(.insertText("[[新想法 "))
        let option = try #require(session.noteLinkMenuState?.options.last)
        #expect(option == .create("新想法"))
        session.chooseNoteLinkOption(option)
        #expect(await eventually { spans(session).contains { $0.linkURL != nil } })
        #expect(requestedTitle == "新想法")
        let link = try #require(spans(session).first { $0.linkURL != nil })
        #expect(link.text == "新想法")
        #expect(NoteLinkURL.noteID(from: link.linkURL) == createdID)
        #expect(spans(session).map(\.text).joined() == "新想法 ")
    }

    @Test func creatingTwiceOrEditingMeanwhileNeverOverwritesText() async throws {
        let (session, _) = session()
        var creations = 0
        session.noteLinkProvider = NoteLinkProvider(
            candidates: { _ in [] },
            open: { _ in },
            create: { _ in
                creations += 1
                // The writer changes what they typed while the note is being created.
                _ = try? session.dispatch(.backspace)
                _ = try? session.dispatch(.insertText("改"))
                return NoteID()
            }
        )
        _ = try session.dispatch(.insertText("[[新"))
        let option = try #require(session.noteLinkMenuState?.options.last)
        session.chooseNoteLinkOption(option)
        session.chooseNoteLinkOption(option)
        #expect(session.noteLinkMenuState == nil)
        #expect(await eventually { creations == 1 && spans(session).map(\.text).joined() == "[[改" })
        for _ in 0..<5 { await Task.yield() }
        #expect(creations == 1)
        #expect(spans(session).allSatisfy { $0.linkURL == nil })
    }

    @Test func typingAfterTheQueryWhileCreatingStillLinksTheQuery() async throws {
        let (session, _) = session()
        let createdID = NoteID()
        session.noteLinkProvider = NoteLinkProvider(
            candidates: { _ in [] },
            open: { _ in },
            create: { _ in
                _ = try? session.dispatch(.insertText("吧"))
                return createdID
            }
        )
        _ = try session.dispatch(.insertText("看[[新"))
        session.chooseNoteLinkOption(try #require(session.noteLinkMenuState?.options.last))
        #expect(await eventually { spans(session).contains { $0.linkURL != nil } })
        #expect(spans(session).map(\.text).joined() == "看新 吧")
        #expect(NoteLinkURL.noteID(from: spans(session).first { $0.linkURL != nil }?.linkURL) == createdID)
    }

    @Test func clickingANoteLinkOpensTheNoteButOtherLinksAreLeftAlone() throws {
        var opened: [NoteID] = []
        let (session, _) = session(opened: { opened.append($0) })
        #expect(session.openNoteLink(NoteLinkURL.url(for: deepWork.id)))
        #expect(session.openNoteLink(URL(string: "https://example.com")!) == false)
        #expect(opened == [deepWork.id])
    }

    @Test func formattingBarButtonStartsALink() throws {
        let (session, _) = session("看 ")
        session.beginNoteLink()
        #expect(spans(session).map(\.text).joined() == "看 [[")
        #expect(session.noteLinkMenuState?.query == "")
    }

    @Test func noteEditorPicksFromTheWorkspaceAndCreatesMissingNotes() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        var target = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        target.title = "深度工作"
        var source = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        source.title = "周计划"
        _ = try await store.sendWorkspace(.createNote(.init(note: target)))
        _ = try await store.sendWorkspace(.createNote(.init(note: source)))
        let persisted = try #require(store.state.notes[source.id])
        let editSessionID = UUID()
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NoteLinkImmediateScheduler())
        try autosave.beginSession(persisted, linkedTaskBlockLinks: [], editSessionID: editSessionID, activeHostToken: UUID())
        var finalizer: NoteNativeInputFinalizer?
        var captured: BlockEditorSession?
        var opened: [NoteID] = []
        let host = NSHostingView(rootView: NoteEditorView(
            identity: .init(noteID: source.id, editSessionID: editSessionID),
            note: persisted,
            focusRegistry: EditorFocusRegistry(),
            autosave: autosave,
            store: store,
            categories: Array(calendar.categories.values),
            onDocumentCommitted: { _ in },
            onTitleCommitted: { _ in },
            onCategoryChanged: { _ in },
            onRequestMarkdownImport: {},
            onRequestMarkdownExport: {},
            onOpenNote: { opened.append($0) },
            sessionSink: { captured = $0 },
            nativeFinalizerHook: Binding(get: { finalizer }, set: { finalizer = $0 })
        ))
        host.frame = .init(x: 0, y: 0, width: 900, height: 620)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        #expect(await eventually { captured?.noteLinkProvider != nil })
        let session = try #require(captured)

        _ = try session.dispatch(.insertText("[[深度"))
        #expect(session.noteLinkMenuState?.options.first == .existing(.init(id: target.id, title: "深度工作", isArchived: false)))
        _ = try session.dispatch(.insertText("思考"))
        let create = try #require(session.noteLinkMenuState?.options.last)
        #expect(create == .create("深度思考"))
        session.chooseNoteLinkOption(create)
        #expect(await eventually { store.state.notes.values.contains { $0.title == "深度思考" } })
        let created = try #require(store.state.notes.values.first { $0.title == "深度思考" })
        #expect(created.categoryID == source.categoryID)
        #expect(await eventually { NoteLinkIndex.outgoingNoteIDs(in: session.document) == [created.id] })

        #expect(session.openNoteLink(NoteLinkURL.url(for: target.id)))
        #expect(opened == [target.id])
    }
}

@MainActor
private final class NoteLinkImmediateScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}
