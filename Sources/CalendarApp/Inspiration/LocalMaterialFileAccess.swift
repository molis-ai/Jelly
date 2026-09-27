import Foundation
import WorkspaceDomain

enum LocalMaterialFileAccessError: Error, Equatable {
    case invalidBookmark
    case staleBookmark
}

protocol MaterialFileBookmarking: Sendable {
    func makeReference(for url: URL) throws -> FileReference
}

protocol MaterialFileAccessing: Sendable {
    func withAccess<T: Sendable>(
        to reference: FileReference,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T
}

struct LocalMaterialFileAccess: MaterialFileBookmarking, MaterialFileAccessing, @unchecked Sendable {
    typealias Resolve = @Sendable (Data) throws -> URL
    typealias Start = @Sendable (URL) -> Bool
    typealias Stop = @Sendable (URL) -> Void

    private let resolve: Resolve
    private let start: Start
    private let stop: Stop

    init() {
        self.init(
            resolve: { data in
                var stale = false
                let url: URL
                do {
                    url = try URL(
                        resolvingBookmarkData: data,
                        options: Self.resolutionOptions,
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale
                    )
                } catch {
                    throw LocalMaterialFileAccessError.invalidBookmark
                }
                guard !stale else { throw LocalMaterialFileAccessError.staleBookmark }
                return url
            },
            start: { $0.startAccessingSecurityScopedResource() },
            stop: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    init(
        resolve: @escaping Resolve,
        start: @escaping Start,
        stop: @escaping Stop
    ) {
        self.resolve = resolve
        self.start = start
        self.stop = stop
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(iOS)
        return [.withoutUI]
        #else
        return [.withSecurityScope, .withoutUI]
        #endif
    }

    private static var creationOptions: URL.BookmarkCreationOptions {
        #if os(iOS)
        return [.minimalBookmark]
        #else
        return [.withSecurityScope]
        #endif
    }

    func makeReference(for url: URL) throws -> FileReference {
        guard url.isFileURL else { throw LocalMaterialFileAccessError.invalidBookmark }
        let data: Data
        do {
            data = try url.bookmarkData(
                options: Self.creationOptions,
                includingResourceValuesForKeys: [.contentTypeKey, .fileSizeKey],
                relativeTo: nil
            )
        } catch {
            throw LocalMaterialFileAccessError.invalidBookmark
        }
        guard !data.isEmpty else { throw LocalMaterialFileAccessError.invalidBookmark }
        return FileReference(bookmarkData: data, displayName: url.lastPathComponent)
    }

    func withAccess<T: Sendable>(
        to reference: FileReference,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        guard !reference.bookmarkData.isEmpty else {
            throw LocalMaterialFileAccessError.invalidBookmark
        }
        let url = try resolve(reference.bookmarkData)
        let started = start(url)
        defer {
            if started { stop(url) }
        }
        return try await body(url)
    }
}
