import AppKit
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("InspirationWorkspaceViewModelTests")
@MainActor
struct InspirationWorkspaceViewModelTests {
    @Test func deepLinkRouterOpensTheExactInspirationInsteadOfKeepingTheFirstRow() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let writer = InspirationViewModel(store: store)
        let first = try await writer.capture("深链第一条")
        try await Task.sleep(for: .milliseconds(20))
        _ = try await writer.capture("深链第二条")
        let router = WorkspaceDeepLinkRouter()
        let host = NSHostingView(rootView: InspirationSplitView(
            store: store,
            newItemRouter: WorkspaceNewItemRouter(),
            deepLinkRouter: router
        ))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        #expect(await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            host.layoutSubtreeIfNeeded()
            return inspirationDescendants(of: host, as: NSTextView.self).contains {
                $0.string == "深链第二条"
            }
        })

        _ = router.request(.inspiration(first))

        #expect(await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            host.layoutSubtreeIfNeeded()
            return inspirationDescendants(of: host, as: NSTextView.self).contains {
                $0.string == "深链第一条"
            }
        })
    }

    @Test func splitEmptyInboxUsesOnlyTheScopeSpecificEmptyState() {
        #expect(InspirationDetailEmptyStatePolicy.showsSelectionPrompt(
            visibleItemCount: 0,
            showsInboxButton: false
        ) == false)
        #expect(InspirationDetailEmptyStatePolicy.showsSelectionPrompt(
            visibleItemCount: 1,
            showsInboxButton: false
        ))
        #expect(InspirationDetailEmptyStatePolicy.showsSelectionPrompt(
            visibleItemCount: 0,
            showsInboxButton: true
        ))
        #expect(InspirationInboxScope.converted.emptyDescription.contains("待处理"))
        #expect(InspirationInboxScope.archived.emptyDescription.contains("归档"))
    }

    @Test func selectedTextInspirationCanBeEditedAndFlushedToDurableState() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let savedAt = Date(timeIntervalSince1970: 1_700_004_200)
        let model = InspirationViewModel(store: store, clock: { savedAt })
        let id = try await model.capture("先记一句")
        model.select(id)

        #expect(model.selectedTextIsEditable)
        model.selectedTextDraft = "先记一句\n再补一句"
        #expect(model.selectedTextSaveState == .waiting)

        await model.flushSelectedTextEdit()

        #expect(store.state.inspirations[id]?.rawText == "先记一句\n再补一句")
        #expect(store.state.inspirations[id]?.updatedAt == savedAt)
        #expect(model.selectedTextSaveState == .saved)
    }

    @Test func blankTextDraftDoesNotOverwriteTheLastSavedInspiration() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = InspirationViewModel(store: store)
        let id = try await model.capture("不能丢的内容")
        model.select(id)

        model.selectedTextDraft = " \n "
        await model.flushSelectedTextEdit()

        #expect(store.state.inspirations[id]?.rawText == "不能丢的内容")
        #expect(model.selectedTextSaveState == .invalid)
    }

    @Test func typingDuringAnInFlightSaveKeepsAndPersistsTheNewestText() async throws {
        let calendar = makeEmptyState()
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        let model = InspirationViewModel(
            store: store,
            textSaveDelay: .seconds(60)
        )
        let id = try await model.capture("初始内容")
        model.select(id)

        await repository.suspendNextSave()
        model.selectedTextDraft = "第一次补写"
        let firstSave = Task { @MainActor in await model.flushSelectedTextEdit() }
        await repository.waitForSaveToStart()

        model.selectedTextDraft = "第一次补写\n保存过程中继续输入"
        await repository.resumeSave()
        await firstSave.value
        await model.flushSelectedTextEdit()

        #expect(store.state.inspirations[id]?.rawText == "第一次补写\n保存过程中继续输入")
        #expect(model.selectedTextDraft == "第一次补写\n保存过程中继续输入")
        #expect(model.selectedTextSaveState == .saved)
    }

    @Test func textCaptureIsDurableBeforeAnyMetadataWork() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let id = try await model.capture("一段原始灵感文字")
        #expect(store.state.inspirations[id]?.rawText == "一段原始灵感文字")
        #expect(resolver.startedURLs.isEmpty)
        #expect(model.pending.map(\.id).contains(id))
    }

    @Test func urlIsDurableBeforeMetadataStarts() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let id = try await model.capture("https://example.com/article")
        #expect(store.state.inspirations[id]?.rawURL == URL(string: "https://example.com/article"))
        #expect(await waitUntil { resolver.startedURLs.count == 1 })
        #expect(resolver.startedURLs.count == 1)
    }

    @Test func metadataFailureIsPersistedInsteadOfRemainingLoadingForever() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let id = try await model.capture("https://example.com/failure")
        #expect(await waitUntil { resolver.startedURLs.count == 1 })

        resolver.fail(URLMetadataResolverError.httpFailure)

        #expect(await waitUntil {
            store.state.inspirations[id]?.resolvedMetadata?.fetchStatus == .failed
        })
        #expect(model.statusMessage == "链接元数据获取失败，原文已保存。")
    }

    @Test func failedMetadataKeepsDomainClassifiedKindForBilibiliVideo() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let id = try await model.capture("https://www.bilibili.com/video/BV1xx411c7mD/")
        #expect(await waitUntil { resolver.startedURLs.count == 1 })

        resolver.fail(URLMetadataResolverError.httpFailure)

        // 播放页常不是规整 HTML，解析失败也要留下域名判定的 kind，且原文不动。
        #expect(await waitUntil {
            store.state.inspirations[id]?.resolvedMetadata?.fetchStatus == .failed
        })
        #expect(store.state.inspirations[id]?.resolvedSourceKind == .video)
        #expect(store.state.inspirations[id]?.rawURL == URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/"))
    }

    @Test func failedMetadataCanBeRetriedAndRecovered() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let id = try await model.capture("https://example.com/retry")
        #expect(await waitUntil { resolver.startedURLs.count == 1 })
        resolver.fail(URLMetadataResolverError.httpFailure)
        #expect(await waitUntil {
            store.state.inspirations[id]?.resolvedMetadata?.fetchStatus == .failed
        })

        model.select(id)
        await model.retrySelectedMetadata()
        #expect(await waitUntil { resolver.startedURLs.count == 2 })
        #expect(store.state.inspirations[id]?.resolvedMetadata?.fetchStatus == .loading)

        resolver.resume(with: .init(
            metadata: .init(
                title: "重试成功",
                siteName: "Example",
                domain: "example.com",
                thumbnailURL: nil,
                fetchStatus: .succeeded
            ),
            resolvedKind: .article
        ))
        #expect(await waitUntil {
            store.state.inspirations[id]?.resolvedMetadata?.fetchStatus == .succeeded
        })
        #expect(store.state.inspirations[id]?.resolvedMetadata?.title == "重试成功")
        #expect(model.statusMessage == nil)
    }

    @Test func convertToNoteIsIdempotentAndOpensExisting() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = InspirationViewModel(store: store)
        let id = try await model.capture("转成笔记的内容")
        model.select(id)
        let first = try await model.convertSelectedToNote()
        let second = try await model.convertSelectedToNote()
        #expect(first != nil)
        #expect(first == second)
        #expect(store.state.notes[first!] != nil)
        #expect(model.converted.map(\.id).contains(id))
    }

    @Test func archiveAndRestorePartitionLifecycle() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = InspirationViewModel(store: store)
        let id = try await model.capture("待归档")
        model.select(id)
        #expect(try await model.archiveSelected())
        #expect(model.archived.map(\.id).contains(id))
        #expect(try await model.restoreSelected())
        #expect(model.pending.map(\.id).contains(id))
    }

    @Test func filteredListSelectionAlwaysMatchesAVisibleRowOrClears() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = InspirationViewModel(store: store)
        let first = try await model.capture("第一条")
        _ = try await model.capture("第二条")

        model.alignSelection(with: [first])
        #expect(model.selectedID == first)

        model.alignSelection(with: [])
        #expect(model.selectedID == nil)
    }

    @Test func selectedInspirationCanMoveToASharedCalendarCategory() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let category = makeCategory(name: "产品")
        _ = try await store.sendWorkspace(.createCategory(category))
        let model = InspirationViewModel(store: store, clock: { .distantFuture })
        let id = try await model.capture("待分类灵感")
        model.select(id)

        #expect(try await model.changeSelectedCategory(to: category.id))
        #expect(store.state.inspirations[id]?.categoryID == category.id)
        #expect(store.state.inspirations[id]?.updatedAt == .distantFuture)
    }

    @Test func archivedInspirationCanBePreviewedAndPermanentlyDeleted() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let deletedAt = Date(timeIntervalSince1970: 1_700_002_000)
        let model = InspirationViewModel(store: store, clock: { deletedAt })
        let id = try await model.capture("准备删除的灵感")
        model.select(id)
        #expect(try await model.archiveSelected())

        let request = try model.permanentDeleteRequest(for: id)
        let authorization = PermanentDeleteAuthorization(
            subject: request.preview.subject,
            sourceWorkspaceRevision: request.preview.sourceWorkspaceRevision,
            impactChecksum: request.preview.checksum
        )
        #expect(try await model.permanentlyDelete(request, authorization: authorization))
        #expect(store.state.inspirations[id] == nil)
        #expect(model.selectedID == nil)
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 200_000_000,
    _ predicate: @MainActor () -> Bool
) async -> Bool {
    let start = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
}

@MainActor
private func inspirationDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    var result = (view as? T).map { [$0] } ?? []
    for child in view.subviews {
        result.append(contentsOf: inspirationDescendants(of: child, as: type))
    }
    return result
}
