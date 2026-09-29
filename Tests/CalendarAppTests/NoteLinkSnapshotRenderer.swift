import AppKit
import CalendarDomain
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

/// Renders the note-link surfaces to PNG for visual review.
///   JELLY_RENDER_SNAPSHOTS=/tmp/out swift test --filter NoteLinkSnapshotRenderer
@Suite("NoteLinkSnapshotRenderer")
@MainActor
struct NoteLinkSnapshotRenderer {
    nonisolated static let output = ProcessInfo.processInfo.environment["JELLY_RENDER_SNAPSHOTS"]

    private func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        let directory = URL(fileURLWithPath: Self.output!, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func render<V: View>(_ name: String, width: CGFloat, _ view: V) throws {
        for scheme in [ColorScheme.light, .dark] {
            let hosting = NSHostingView(rootView: view
                .environment(\.colorScheme, scheme)
                .padding(16)
                .frame(width: width)
                .background(CalendarTheme.appearance(for: scheme).canvas))
            hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try write(rep, "\(name)-\(scheme == .dark ? "dark" : "light")")
        }
    }

    @Test(.enabled(if: NoteLinkSnapshotRenderer.output != nil))
    func renderNoteLinkSurfaces() async throws {
        let deepWork = NoteLinkCandidate(id: NoteID(), title: "深度工作的三个前提", isArchived: false)
        let weekly = NoteLinkCandidate(id: NoteID(), title: "工作周报模板", isArchived: true)
        try render("note-link-menu", width: 420, NoteLinkMenu(
            state: NoteLinkMenuState(
                blockID: BlockID(),
                queryRange: 0..<4,
                query: "工作",
                options: [.existing(deepWork), .existing(weekly), .create("工作")],
                selectedIndex: 0
            ),
            onChoose: { _ in },
            onDismiss: {}
        ))
        try render("note-link-menu-empty", width: 420, NoteLinkMenu(
            state: NoteLinkMenuState(blockID: BlockID(), queryRange: 0..<5, query: "没有", options: [], selectedIndex: 0),
            onChoose: { _ in },
            onDismiss: {}
        ))
        try render("note-backlinks", width: 372, NoteBacklinksPopover(
            backlinks: [
                NoteBacklink(sourceNoteID: NoteID(), sourceTitle: "周计划", blockID: BlockID(), excerpt: "这周先读完 深度工作的三个前提，再决定要不要把上午整块留出来。", sourceIsArchived: false),
                NoteBacklink(sourceNoteID: NoteID(), sourceTitle: "2025 年复盘", blockID: BlockID(), excerpt: "参考 深度工作的三个前提", sourceIsArchived: true)
            ],
            onOpen: { _ in }
        ))

        // The real editor, with a note that two others link to and the picker open.
        let calendar = makeEmptyState()
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: InMemoryWorkspaceRepository(initialState: calendar))
        await store.load()
        var target = Note.empty(categoryID: calendar.uncategorizedID, now: .now)
        target.title = "深度工作的三个前提"
        target.document = BlockDocument(blocks: [
            .init(id: BlockID(), kind: .paragraph, inlineContent: .plain("一、整块的时间；二、关掉通知；三、事先想清楚要做什么。"), taskState: nil, indentLevel: 0)
        ])
        _ = try await store.sendWorkspace(.createNote(.init(note: target)))
        for (title, text) in [("周计划", "这周先读完 "), ("2025 年复盘", "参考 ")] {
            var source = Note.empty(categoryID: calendar.uncategorizedID, now: .now)
            source.title = title
            source.document = BlockDocument(blocks: [.init(
                id: BlockID(), kind: .paragraph,
                inlineContent: InlineContent(spans: [
                    InlineSpan(text: text),
                    InlineSpan(text: target.title, linkURL: NoteLinkURL.url(for: target.id))
                ]),
                taskState: nil, indentLevel: 0
            )])
            _ = try await store.sendWorkspace(.createNote(.init(note: source)))
        }
        let persisted = try #require(store.state.notes[target.id])
        let editSessionID = UUID()
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: SnapshotImmediateScheduler())
        try autosave.beginSession(persisted, linkedTaskBlockLinks: [], editSessionID: editSessionID, activeHostToken: UUID())
        var finalizer: NoteNativeInputFinalizer?
        var captured: BlockEditorSession?
        let host = NSHostingView(rootView: NoteEditorView(
            identity: .init(noteID: target.id, editSessionID: editSessionID),
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
            sessionSink: { captured = $0 },
            nativeFinalizerHook: Binding(get: { finalizer }, set: { finalizer = $0 })
        ).environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = .init(x: 0, y: 0, width: 900, height: 560)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #expect(await eventually { captured?.noteLinkProvider != nil })
        let session = try #require(captured)
        session.focusDocumentEnd()
        _ = try session.dispatch(.insertText(" 延伸：[[周"))
        for _ in 0..<5 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
        host.display()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try write(rep, "note-editor-with-links")
    }
}

@MainActor
private final class SnapshotImmediateScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}
