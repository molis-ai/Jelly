import Foundation
import WorkspaceDomain

/// Turns raw captured text into an inspiration. Shared by the 灵感 page, the
/// global quick-capture panel, the Services menu and the iOS App Intent so a
/// thought captured anywhere is stored the same way.
enum InspirationCaptureBuilder {
    static func inspiration(
        from raw: String,
        id: InspirationID = InspirationID(),
        categoryID: UUID,
        now: Date
    ) -> Inspiration? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = webURL(trimmed) {
            return Inspiration(
                id: id,
                inputKind: .url,
                rawText: nil,
                rawURL: url,
                rawFile: nil,
                resolvedSourceKind: SourceKindClassifier.classify(url) ?? .unknown,
                resolvedMetadata: SourceMetadata(
                    title: nil, siteName: nil, domain: url.host, thumbnailURL: nil, fetchStatus: .loading
                ),
                categoryID: categoryID,
                lifecycle: .active,
                createdAt: now,
                updatedAt: now
            )
        }
        return Inspiration.text(id: id, rawText: trimmed, categoryID: categoryID, now: now)
    }

    /// Only a bare http(s) link counts as a URL capture; text that merely
    /// contains a link stays text so nothing the user typed is dropped.
    static func webURL(_ trimmed: String) -> URL? {
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

enum InspirationMetadataEnrichmentOutcome: Equatable, Sendable {
    case updated
    case failedRecorded
    case failedUnrecorded
    case sourceChanged
}

enum InspirationMetadataEnricher {
    @MainActor
    static func enrich(
        store: WorkspaceStore,
        resolver: any URLMetadataResolving,
        id: InspirationID,
        url: URL,
        onResolveFailed: @MainActor () -> Void = {}
    ) async -> InspirationMetadataEnrichmentOutcome {
        guard let current = store.state.inspirations[id] else { return .sourceChanged }
        let sourceChecksum = WorkspaceChecksum.inspirationSourceChecksum(current)
        do {
            let result = try await resolver.resolve(url)
            _ = try await store.sendWorkspace(
                .updateInspirationMetadata(
                    id,
                    expectedSource: .init(sourceChecksum: sourceChecksum),
                    metadata: result.metadata,
                    resolvedKind: result.resolvedKind
                )
            )
            return .updated
        } catch {
            onResolveFailed()
            guard let latest = store.state.inspirations[id],
                  WorkspaceChecksum.inspirationSourceChecksum(latest) == sourceChecksum
            else {
                return .sourceChanged
            }
            var failedMetadata = latest.resolvedMetadata ?? SourceMetadata(
                title: nil,
                siteName: nil,
                domain: latest.rawURL?.host,
                thumbnailURL: nil,
                fetchStatus: .failed
            )
            failedMetadata.fetchStatus = .failed
            // 解析失败也要留下域名能判定的 kind，B 站 / 小宇宙播放页常不是规整 HTML。
            let failedKind = SourceKindClassifier.classify(url) ?? latest.resolvedSourceKind
            do {
                _ = try await store.sendWorkspace(
                    .updateInspirationMetadata(
                        id,
                        expectedSource: .init(sourceChecksum: sourceChecksum),
                        metadata: failedMetadata,
                        resolvedKind: failedKind
                    )
                )
                return .failedRecorded
            } catch {
                return .failedUnrecorded
            }
        }
    }
}

enum InspirationCaptureOrigin: String, Sendable {
    case inspirationPage
    case quickCapture
    case servicesMenu
    case shortcut
}

@MainActor
final class InspirationCaptureService {
    private let store: WorkspaceStore
    private let metadataResolver: any URLMetadataResolving
    private let followUp: InspirationFollowUpService?
    private let clock: @Sendable () -> Date

    init(
        store: WorkspaceStore,
        metadataResolver: any URLMetadataResolving = URLMetadataResolver(),
        followUp: InspirationFollowUpService? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.metadataResolver = metadataResolver
        self.followUp = followUp
        self.clock = clock
    }

    /// Stores the text exactly as given, then enriches links and asks for an
    /// expansion in the background. The caller never waits on the network.
    @discardableResult
    func capture(_ raw: String, origin: InspirationCaptureOrigin) async throws -> InspirationID {
        guard let inspiration = InspirationCaptureBuilder.inspiration(
            from: raw,
            categoryID: store.calendarState.uncategorizedID,
            now: clock()
        ) else {
            throw InspirationCaptureError.empty
        }
        let categoryName = store.calendarState.categories[inspiration.categoryID]?.name ?? "未分类"
        let outcome = try await store.sendWorkspace(
            .createInspiration(.init(inspiration: inspiration)),
            undoLabel: WorkspaceCreationFeedback.inspiration(
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                categoryName: categoryName
            )
        )
        guard case .committed = outcome else { throw InspirationCaptureError.notCommitted }
        if inspiration.inputKind == .url, let url = inspiration.rawURL {
            let store = store
            let resolver = metadataResolver
            Task { @MainActor in
                _ = await InspirationMetadataEnricher.enrich(store: store, resolver: resolver, id: inspiration.id, url: url)
            }
        } else {
            followUp?.expandIfEnabled(inspiration.id)
        }
        return inspiration.id
    }
}
