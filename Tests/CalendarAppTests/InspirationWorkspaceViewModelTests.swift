import AppKit
import CalendarPersistence
import Foundation
import Observation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("InspirationWorkspaceViewModelTests")
@MainActor
struct InspirationWorkspaceViewModelTests {
    @Test func editingDigestedTextSavesTheNewSourceAndStopsTheStalePipeline() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let digestOperator = RecordingMaterialDigestOperator()
        let model = InspirationViewModel(
            store: store,
            digestOperator: digestOperator,
            textSaveDelay: .seconds(30)
        )
        let id = try await model.capture("原来的材料")
        let inspiration = try #require(store.state.inspirations[id])
        try await seedSucceededDigest(for: inspiration, in: store, now: .distantPast)
        model.select(id)

        model.selectedTextDraft = "用户修改后的材料"
        await model.flushSelectedTextEdit()

        #expect(store.state.inspirations[id]?.rawText == "用户修改后的材料")
        #expect(store.state.materialDigests[id] == nil)
        #expect(digestOperator.stops == [id])
        #expect(model.selectedTextSaveState == .saved)
    }

    @Test func uncertainDigestWriteKeepsVisibleRecoveryUntilTheExactCommitIsConfirmed() async throws {
        let calendar = makeEmptyState()
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: repository
        )
        await store.load()
        let now = Date(timeIntervalSince1970: 1_800_320_000)
        let inspiration = Inspiration(
            id: InspirationID(),
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!,
            rawFile: nil,
            resolvedSourceKind: .video,
            resolvedMetadata: .init(
                title: "待写入的视频",
                siteName: "B站",
                domain: "bilibili.com",
                thumbnailURL: nil,
                fetchStatus: .succeeded
            ),
            categoryID: calendar.uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.sendWorkspace(.createInspiration(.init(inspiration: inspiration)))
        try await seedSucceededDigest(for: inspiration, in: store, now: now)
        let model = InspirationViewModel(store: store)
        model.select(inspiration.id)
        let expectedRevision = store.state.revision + 1
        await repository.makeNextSaveUncertain()

        #expect(try await model.convertSelectedToNote() == nil)
        #expect(model.selectedPrimaryActionTitle == "继续确认写入")
        #expect(model.statusMessage == "写入结果尚未确认，原始灵感仍保留。请继续确认。")
        #expect(store.state.inspirationNoteLinks.isEmpty)

        await repository.setReconciliation(.committed(.save(.init(
            workspaceRevision: expectedRevision,
            persistedDraft: nil
        ))))
        let noteID = try #require(try await model.convertSelectedToNote())

        #expect(store.state.inspirationNoteLinks.contains { link in
            link.noteID == noteID && link.source == .live(inspiration.id)
        })
        #expect(model.selectedPrimaryActionTitle == "打开笔记")
        #expect(model.statusMessage == "提炼摘要已写入笔记。")
    }

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

    @Test func captureDoesNotStartMaterialDigest() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let recorder = RecordingMaterialDigestOperator()
        let model = InspirationViewModel(
            store: store,
            metadataResolver: resolver,
            digestOperator: recorder
        )
        let id = try await model.capture("https://www.bilibili.com/video/BV1xx411c7mD/")
        #expect(recorder.starts.isEmpty)
        #expect(recorder.confirms.isEmpty)
        #expect(store.state.inspirations[id]?.resolvedSourceKind == .video)
        #expect(model.selectedDigestPresentation.primaryActionTitle == "提炼这份材料")
        model.select(id)
        #expect(try await model.archiveSelected())
        #expect(recorder.starts.isEmpty)
    }

    @Test func captureFilePersistsReferenceWithoutStartingDigest() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let recorder = RecordingMaterialDigestOperator()
        let model = InspirationViewModel(store: store, digestOperator: recorder)
        let reference = FileReference(bookmarkData: Data([1, 2, 3]), displayName: "材料.pdf")

        let id = try await model.captureFile(reference, kind: .document)
        let saved = try #require(store.state.inspirations[id])

        #expect(saved.inputKind == .file)
        #expect(saved.rawFile == reference)
        #expect(saved.resolvedSourceKind == .document)
        #expect(recorder.starts.isEmpty)
        #expect(model.selectedID == id)
        #expect(model.selectedDigestPresentation.isVisible)
        #expect(model.selectedDigestPresentation.primaryActionTitle == "提炼这份材料")
    }

    @Test func unconfiguredDigestStillStartsAcquisitionBeforeTheRuntimeCheck() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let recorder = RecordingMaterialDigestOperator()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(
            store: store,
            metadataResolver: resolver,
            digestOperator: recorder,
            isDigestConfigured: { false }
        )
        let id = try await model.capture("https://www.bilibili.com/video/BV1xx411c7mD/")
        #expect(await waitUntil { resolver.startedURLs.count == 1 })
        resolver.fail(URLMetadataResolverError.httpFailure)
        #expect(await waitUntil {
            store.state.inspirations[id]?.resolvedSourceKind == .video
        })
        model.select(id)
        #expect(model.selectedDigestPresentation.showsOpenSettings == false)
        #expect(model.selectedDigestPresentation.primaryActionTitle == "提炼这份材料")
        await model.startSelectedDigest()
        #expect(recorder.starts == [id])
    }

    @Test func completedDigestCanExplicitlyRefreshTheSource() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let recorder = RecordingMaterialDigestOperator()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(
            store: store,
            metadataResolver: resolver,
            digestOperator: recorder
        )
        let id = try await model.capture("https://www.bilibili.com/video/BV1xx411c7mD/")
        #expect(await waitUntil { resolver.startedURLs.count == 1 })
        resolver.fail(URLMetadataResolverError.httpFailure)
        #expect(await waitUntil { store.state.inspirations[id]?.resolvedSourceKind == .video })
        let inspiration = try #require(store.state.inspirations[id])
        try await seedSucceededDigest(for: inspiration, in: store, now: .distantFuture)
        model.refresh()
        model.select(id)

        #expect(model.selectedDigestPresentation.showsRefresh)
        await model.refreshSelectedDigest()
        #expect(recorder.starts == [id])
        #expect(recorder.startModes == [.refreshSource])
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

    @Test func failedBilibiliMetadataKeepsVideoKindAndRawURL() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let raw = "https://www.bilibili.com/video/BV1xx411c7mD/"
        let id = try await model.capture(raw)
        #expect(store.state.inspirations[id]?.rawURL == URL(string: raw))
        #expect(await waitUntil { resolver.startedURLs.count == 1 })

        resolver.fail(URLMetadataResolverError.httpFailure)

        #expect(await waitUntil {
            store.state.inspirations[id]?.resolvedMetadata?.fetchStatus == .failed
        })
        #expect(store.state.inspirations[id]?.resolvedSourceKind == .video)
        #expect(store.state.inspirations[id]?.rawURL == URL(string: raw))
        #expect(model.statusMessage == "链接元数据获取失败，原文已保存。")
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

    @Test func backgroundMetadataFailureDoesNotLeakIntoAnotherMaterial() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let urlID = try await model.capture("https://example.com/slow-failure")
        #expect(await waitUntil { resolver.startedURLs.count == 1 })
        let textID = try await model.capture("当前正在查看的文字材料")

        resolver.fail(URLMetadataResolverError.httpFailure)

        #expect(await waitUntil {
            store.state.inspirations[urlID]?.resolvedMetadata?.fetchStatus == .failed
        })
        #expect(model.selectedID == textID)
        #expect(model.statusMessage == nil)
    }

    @Test func convertSuccessfulDigestWritesLinkThenStructuredSummaryBlocks() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = InspirationViewModel(store: store)
        let now = Date(timeIntervalSince1970: 1_800_310_000)
        let inspiration = Inspiration(
            id: InspirationID(),
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!,
            rawFile: nil,
            resolvedSourceKind: .video,
            resolvedMetadata: .init(
                title: "视频标题",
                siteName: "B站",
                domain: "bilibili.com",
                thumbnailURL: nil,
                fetchStatus: .succeeded
            ),
            categoryID: calendar.uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.sendWorkspace(.createInspiration(.init(inspiration: inspiration)))
        try await seedSucceededDigest(for: inspiration, in: store, now: now)
        model.select(inspiration.id)
        let noteID = try #require(try await model.convertSelectedToNote())
        let blocks = try #require(store.state.notes[noteID]?.document.blocks)
        #expect(blocks.map(\.kind) == [
            .link, .heading2, .paragraph, .heading2,
            .bullet, .bullet, .bullet,
            .heading2, .bullet, .bullet, .bullet, .bullet,
            .heading2, .bullet,
            .heading2, .bullet
        ])
        let texts = blocks.map { $0.inlineContent.spans.map(\.text).joined() }
        #expect(blocks[0].inlineContent.spans[0].linkURL == inspiration.rawURL)
        #expect(texts[1] == "核心观点")
        #expect(texts[2] == "核心论点")
        #expect(texts[3] == "主要观点")
        #expect(blocks[4].kind == .bullet)
        #expect(texts.contains("章节"))
        #expect(texts.contains("引用"))
        #expect(texts.contains("未纳入摘要"))
        let repeated = try await model.convertSelectedToNote()
        #expect(repeated == noteID)
        #expect(store.state.notes.count == 1)
    }

    @Test func convertTextAndFileMaterialsPreservesSourceThenWritesDigest() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = InspirationViewModel(store: store)
        let now = Date(timeIntervalSince1970: 1_800_310_100)

        let textID = try await model.capture("原始正文必须保留")
        let text = try #require(store.state.inspirations[textID])
        try await seedSucceededDigest(for: text, in: store, now: now)
        model.refresh()
        model.select(textID)
        let textNoteID = try #require(try await model.convertSelectedToNote())
        let textDocument = try #require(store.state.notes[textNoteID]?.document)
        let textPlain = textDocument.blocks
            .map { $0.inlineContent.spans.map(\.text).joined() }
            .joined(separator: "\n")
        #expect(textDocument.blocks.first?.inlineContent.spans.map(\.text).joined() == "原始正文必须保留")
        #expect(textPlain.contains("核心观点"))
        #expect(textPlain.contains("核心论点"))

        let fileID = try await model.captureFile(
            FileReference(bookmarkData: Data([1, 2, 3]), displayName: "材料.txt"),
            kind: .document
        )
        let file = try #require(store.state.inspirations[fileID])
        try await seedSucceededDigest(for: file, in: store, now: now)
        model.refresh()
        model.select(fileID)
        let fileNoteID = try #require(try await model.convertSelectedToNote())
        let fileDocument = try #require(store.state.notes[fileNoteID]?.document)
        let filePlain = fileDocument.blocks
            .map { $0.inlineContent.spans.map(\.text).joined() }
            .joined(separator: "\n")
        #expect(fileDocument.blocks.first?.inlineContent.spans.map(\.text).joined() == "材料文件：材料.txt")
        #expect(filePlain.contains("核心观点"))
        #expect(filePlain.contains("核心论点"))
        #expect(model.statusMessage == "提炼摘要已写入笔记。")

        model.alignSelection(with: [textID])
        #expect(model.selectedID == textID)
        #expect(model.statusMessage == nil)
    }

    @Test func convertWithoutUsableDigestKeepsOnlyTheOriginalLink() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = InspirationViewModel(store: store)
        let now = Date(timeIntervalSince1970: 1_800_310_100)
        let inspiration = Inspiration(
            id: InspirationID(),
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!,
            rawFile: nil,
            resolvedSourceKind: .video,
            resolvedMetadata: nil,
            categoryID: calendar.uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.sendWorkspace(.createInspiration(.init(inspiration: inspiration)))
        model.select(inspiration.id)
        let runningNoteID = try #require(try await model.convertSelectedToNote())
        let runningBlocks = try #require(store.state.notes[runningNoteID]?.document.blocks)
        #expect(runningBlocks.map(\.kind) == [.link])

        let failed = Inspiration(
            id: InspirationID(),
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://www.xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e")!,
            rawFile: nil,
            resolvedSourceKind: .audio,
            resolvedMetadata: nil,
            categoryID: calendar.uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.sendWorkspace(.createInspiration(.init(inspiration: failed)))
        let checksum = WorkspaceChecksum.inspirationSourceChecksum(failed)
        let runID = MaterialDigestRunID()
        _ = try await store.sendWorkspace(.startMaterialDigest(.init(
            inspirationID: failed.id,
            digestID: MaterialDigestID(),
            runID: runID,
            expectedSourceChecksum: checksum
        )))
        _ = try await store.sendWorkspace(.failMaterialDigest(.init(
            expectation: .init(inspirationID: failed.id, runID: runID, sourceChecksum: checksum),
            code: .sourceUnavailable,
            userMessage: "暂时无法获取材料，原始链接仍然保留。"
        )))
        model.select(failed.id)
        let failedNoteID = try #require(try await model.convertSelectedToNote())
        #expect(store.state.notes[failedNoteID]?.document.blocks.map(\.kind) == [.link])
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

    @Test func digestCompletedAfterConversionCanBeWrittenToTheExistingNoteOnce() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let now = Date(timeIntervalSince1970: 1_800_310_200)
        let inspiration = Inspiration(
            id: InspirationID(),
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!,
            rawFile: nil,
            resolvedSourceKind: .video,
            resolvedMetadata: nil,
            categoryID: calendar.uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.sendWorkspace(.createInspiration(.init(inspiration: inspiration)))
        let model = InspirationViewModel(store: store)
        model.select(inspiration.id)
        let noteID = try #require(try await model.convertSelectedToNote())
        #expect(store.state.notes[noteID]?.document.blocks.map(\.kind) == [.link])

        try await seedSucceededDigest(for: inspiration, in: store, now: now)
        #expect(model.selectedPrimaryActionTitle == "写入笔记")
        #expect(try await model.convertSelectedToNote() == noteID)
        let firstWrite = try #require(store.state.notes[noteID]?.document.blocks)
        #expect(firstWrite.first?.kind == .link)
        #expect(firstWrite.contains(where: {
            $0.inlineContent.spans.map(\.text).joined() == "核心论点"
        }))

        #expect(model.selectedPrimaryActionTitle == "打开笔记")
        #expect(try await model.convertSelectedToNote() == noteID)
        #expect(store.state.notes[noteID]?.document.blocks == firstWrite)
        #expect(store.state.notes.count == 1)
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
        let digestOperator = RecordingMaterialDigestOperator()
        let model = InspirationViewModel(
            store: store,
            digestOperator: digestOperator,
            clock: { deletedAt }
        )
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
        #expect(digestOperator.stops == [id])
        #expect(model.selectedID == nil)
    }
}

@MainActor
@Observable
final class RecordingMaterialDigestOperator: MaterialDigestOperating {
    var starts: [InspirationID] = []
    var startModes: [MaterialDigestStartMode] = []
    var confirms: [InspirationID] = []
    var cancels: [InspirationID] = []
    var stops: [InspirationID] = []
    var reconciles = 0

    func start(inspirationID: InspirationID, mode: MaterialDigestStartMode) async {
        starts.append(inspirationID)
        startModes.append(mode)
    }
    func confirmModelDownload(inspirationID: InspirationID) async { confirms.append(inspirationID) }
    func cancel(inspirationID: InspirationID) async { cancels.append(inspirationID) }
    func stopExternalWork(inspirationID: InspirationID) async { stops.append(inspirationID) }
    func reconcileInterruptedRuns() async { reconciles += 1 }
    func progress(for inspirationID: InspirationID) -> Double? { nil }
}

@MainActor
private func seedSucceededDigest(
    for inspiration: Inspiration,
    in store: WorkspaceStore,
    now: Date
) async throws {
    let checksum = WorkspaceChecksum.inspirationSourceChecksum(inspiration)
    let runID = MaterialDigestRunID()
    let expectation = MaterialDigestRunExpectation(
        inspirationID: inspiration.id,
        runID: runID,
        sourceChecksum: checksum
    )
    let snapshot = try materialSnapshot(for: checksum)
    _ = try await store.sendWorkspace(.startMaterialDigest(.init(
        inspirationID: inspiration.id,
        digestID: MaterialDigestID(),
        runID: runID,
        expectedSourceChecksum: checksum
    )))
    _ = try await store.sendWorkspace(.saveMaterialSnapshot(.init(
        expectation: expectation,
        snapshot: snapshot
    )))
    _ = try await store.sendWorkspace(.advanceMaterialDigestStage(.init(
        expectation: expectation,
        stage: .summarizing
    )))
    _ = try await store.sendWorkspace(.completeMaterialDigest(.init(
        expectation: expectation,
        expectedContentFingerprint: snapshot.contentFingerprint,
        summary: InspirationSummary(
            thesis: "核心论点",
            takeaways: ["观点1", "观点2", "观点3"],
            chapters: [
                DigestChapter(startSeconds: 0, title: "开场", points: ["引入"]),
                DigestChapter(startSeconds: 8, title: "主体", points: ["展开"])
            ],
            quotes: [DigestQuote(speaker: nil, startSeconds: 8, text: "主体")],
            dropped: ["片头"]
        ),
        provenance: DigestProvenance(
            modelIdentifier: "api.example.com/test-model",
            generatedAt: now,
            inputFingerprint: checksum,
            summaryContractVersion: "summary-contract-v1"
        )
    )))
}

private func materialSnapshot(for sourceChecksum: String) throws -> MaterialSnapshot {
    let blocks = [
        MaterialBlock(
            id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000a001")!),
            role: .transcript,
            text: "开场",
            locator: .timestamp(startSeconds: 0, endSeconds: 8),
            confidence: nil
        ),
        MaterialBlock(
            id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000a002")!),
            role: .transcript,
            text: "主体",
            locator: .timestamp(startSeconds: 8, endSeconds: 20),
            confidence: nil
        )
    ]
    let draft = MaterialSnapshot(
        sourceChecksum: sourceChecksum,
        contentFingerprint: "pending",
        blocks: blocks,
        coverage: .sufficient,
        provenance: MaterialAcquisitionProvenance(
            adapterIdentifier: "test-adapter",
            adapterVersion: "1",
            acquiredAt: Date(timeIntervalSince1970: 1_800_000_000)
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    return MaterialSnapshot(
        sourceChecksum: sourceChecksum,
        contentFingerprint: try WorkspaceChecksum.materialSnapshotContentFingerprint(draft),
        blocks: blocks,
        coverage: draft.coverage,
        provenance: draft.provenance,
        createdAt: draft.createdAt
    )
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
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
