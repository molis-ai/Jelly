import AppKit
import CalendarDomain
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WorkspaceSurfacePresentationTests")
@MainActor
struct WorkspaceSurfacePresentationTests {
    @Test func creationFeedbackNamesTheObjectAndItsLocation() throws {
        let date = try #require(CalendarDate(year: 2026, month: 8, day: 15))

        #expect(WorkspaceCreationFeedback.calendar(
            title: "产品复盘",
            date: date,
            categoryName: "工作"
        ) == "已创建《产品复盘》 · 8月15日 · 工作")
        #expect(WorkspaceCreationFeedback.note(categoryName: "生活") == "已新建笔记 · 生活")
        #expect(WorkspaceCreationFeedback.inspiration(
            text: "研究新的编辑器方案",
            categoryName: "未分类"
        ) == "已捕获“研究新的编辑器方案” · 未分类")
    }

    @Test func globalUndoToastAcceptsOnlyCreationResults() {
        #expect(WorkspaceCreationFeedback.isCreationUndoLabel("已创建《复盘》 · 8月15日 · 工作"))
        #expect(WorkspaceCreationFeedback.isCreationUndoLabel("已新建笔记 · 生活"))
        #expect(WorkspaceCreationFeedback.isCreationUndoLabel("已捕获“想法” · 未分类"))
        #expect(!WorkspaceCreationFeedback.isCreationUndoLabel("编辑笔记"))
        #expect(!WorkspaceCreationFeedback.isCreationUndoLabel("归档灵感"))
    }

    @Test func appShellCreationNoticeTracksTheCurrentUndoRecordWithoutGoingStale() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let item = try makeItem(
            categoryID: calendar.uncategorizedID,
            title: "产品复盘",
            date: try #require(CalendarDate(year: 2026, month: 8, day: 15))
        )

        _ = try await store.sendCalendar(
            .createItem(item),
            undoLabel: "已创建《产品复盘》 · 8月15日 · 未分类"
        )

        let notice = try #require(WorkspaceCreationNotice.resolve(
            stateGeneration: store.statePublicationGeneration,
            undoLabel: store.latestUndoLabel
        ))
        #expect(notice.undoLabel == "已创建《产品复盘》 · 8月15日 · 未分类")

        var renamed = item
        renamed.title = "产品复盘（已编辑）"
        _ = try await store.sendCalendar(.updateItem(renamed), undoLabel: "编辑事项")

        #expect(store.statePublicationGeneration != notice.stateGeneration)
        #expect(WorkspaceCreationNotice.resolve(
            stateGeneration: store.statePublicationGeneration,
            undoLabel: store.latestUndoLabel
        ) == nil)
    }

    @Test func articleInspirationShowsTheSharedManualDigestAction() {
        let inspiration = Inspiration(
            id: InspirationID(),
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://example.com/post")!,
            rawFile: nil,
            resolvedSourceKind: .article,
            resolvedMetadata: nil,
            categoryID: UUID(),
            lifecycle: .active,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let presentation = MaterialDigestPresentation.project(
            inspiration: inspiration,
            digest: nil,
            operatorAvailable: true
        )
        #expect(presentation.isVisible)
        #expect(presentation.primaryActionTitle == "提炼这份材料")
    }

    @Test func notesUsesOnePaneAtCompactWidthsAndNeverClipsTheEditorBehindTheBrowser() {
        #expect(NotesAdaptiveLayout.mode(width: 640, browserCollapsed: false) == .browserOnly)
        #expect(NotesAdaptiveLayout.mode(width: 640, browserCollapsed: true) == .editorOnly)
        #expect(NotesAdaptiveLayout.mode(width: 980, browserCollapsed: false) == .split)
        #expect(NotesAdaptiveLayout.mode(width: 980, browserCollapsed: true) == .editorOnly)
    }

    @Test func noteBrowserPresentsOneExplicitScopeInsteadOfDuplicatingRowsAcrossSections() async throws {
        let calendar = makeEmptyState()
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        var note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        note.title = "只出现一次"
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let model = NotesWorkspaceViewModel(store: store, autosave: NoteAutosaveCoordinator(store: store))

        #expect(model.displayedNotes(in: .recent).map(\.id) == [note.id])
        #expect(model.displayedNotes(in: .all).map(\.id) == [note.id])
        #expect(model.displayedNotes(in: .archived).isEmpty)
        #expect(NotesBrowserPartition.allCases.map(\.title) == ["最近", "全部", "归档"])
    }

    @Test func emptyBlockEditorExplainsWhereWritingStarts() {
        let textView = BlockEditorTextView()
        #expect(textView.accessibilityPlaceholderValue() == "开始写点什么…")
    }

    @Test func inspirationCategoryFilterNarrowsEveryLifecyclePartition() async throws {
        let calendar = makeEmptyState()
        let work = makeCategory(name: "工作")
        var calendarWithWork = calendar
        calendarWithWork.categories[work.id] = work
        let repository = InMemoryWorkspaceRepository(initialState: calendarWithWork)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendarWithWork),
            repository: repository
        )
        await store.load()
        let model = InspirationViewModel(store: store, metadataResolver: FailingSurfaceMetadataResolver())
        _ = try await model.capture("未分类灵感")
        _ = try await model.capture("工作灵感")
        _ = try await model.changeSelectedCategory(to: work.id)

        model.categoryFilterID = work.id

        #expect(model.pending.map(\.rawText) == ["工作灵感"])
        #expect(model.converted.isEmpty)
        #expect(model.archived.isEmpty)
    }

    @Test func convertedInspirationExposesItsExistingNoteAsThePrimaryAction() async throws {
        let calendar = makeEmptyState()
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        let model = InspirationViewModel(store: store, metadataResolver: FailingSurfaceMetadataResolver())
        _ = try await model.capture("已有去向的灵感")
        let noteID = try #require(try await model.convertSelectedToNote())

        #expect(model.selectedConvertedNoteID == noteID)
        #expect(model.selectedPrimaryActionTitle == "打开笔记")
    }

    @Test func pendingInspirationDescribesConversionAsContinuingTheThought() async throws {
        let calendar = makeEmptyState()
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        let model = InspirationViewModel(store: store, metadataResolver: FailingSurfaceMetadataResolver())
        _ = try await model.capture("还想继续展开的想法")

        #expect(model.selectedPrimaryActionTitle == "继续写成笔记")
        #expect(model.selectedTextIsEditable)
    }

    @Test func metadataStatesUseUserFacingChineseInsteadOfPersistenceRawValues() {
        #expect(MetadataFetchStatus.notRequested.presentationTitle == "未请求")
        #expect(MetadataFetchStatus.loading.presentationTitle == "获取中…")
        #expect(MetadataFetchStatus.succeeded.presentationTitle == "已获取")
        #expect(MetadataFetchStatus.failed.presentationTitle == "获取失败")
    }

    @Test func inspirationScopeFollowsTheSelectedItemsLifecycleAndConversion() {
        #expect(InspirationInboxScope.preferred(lifecycle: .active, isConverted: false) == .pending)
        #expect(InspirationInboxScope.preferred(lifecycle: .active, isConverted: true) == .converted)
        #expect(InspirationInboxScope.preferred(lifecycle: .archived, isConverted: true) == .archived)
    }

    @Test func inspirationDetailExposesOnePrimaryPathAndSeparateSecondaryActionContracts() {
        #expect(InspirationDetailAction.allCases.map(\.rawValue) == [
            "inspiration-primary-action",
            "inspiration-archive-action",
            "inspiration-copy-link-action",
        ])
    }
}

@MainActor
private func workspaceSurfaceDescendants<View: NSView>(
    of view: NSView,
    as type: View.Type
) -> [View] {
    let own = (view as? View).map { [$0] } ?? []
    return own + view.subviews.flatMap { workspaceSurfaceDescendants(of: $0, as: type) }
}

@MainActor
private func workspaceSurfaceWaitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private final class FailingSurfaceMetadataResolver: URLMetadataResolving, @unchecked Sendable {
    func resolve(_ url: URL) async throws -> URLMetadataResolveResult {
        throw CocoaError(.fileReadUnknown)
    }
}
