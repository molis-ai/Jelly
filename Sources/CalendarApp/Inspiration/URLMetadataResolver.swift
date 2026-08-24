import Foundation
import WorkspaceDomain

/// Best-effort URL enrichment with timeout, size cap and no script execution.
/// Failures never overwrite the durable raw URL inspiration.
final class URLMetadataResolver: URLMetadataResolving, @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval
    private let maxBytes: Int

    init(
        timeout: TimeInterval = 8,
        maxBytes: Int = 256_000,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        let config = configuration
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
        self.timeout = timeout
        self.maxBytes = maxBytes
    }

    func resolve(_ url: URL) async throws -> URLMetadataResolveResult {
        // 域名能判定的源不依赖 HTML 解析结果；解析失败时由调用方兜底保留同一判定。
        let classifiedKind = SourceKindClassifier.classify(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw URLMetadataResolverError.httpFailure
        }
        guard let mimeType = http.mimeType?.lowercased(),
              mimeType == "text/html" || mimeType == "application/xhtml+xml"
        else {
            throw URLMetadataResolverError.unsupportedContentType
        }
        if http.expectedContentLength > Int64(maxBytes) {
            throw URLMetadataResolverError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, max(0, Int(http.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maxBytes else {
                throw URLMetadataResolverError.responseTooLarge
            }
            data.append(byte)
        }
        let html = String(decoding: data, as: UTF8.self)
        let title = Self.extractTitle(from: html) ?? url.host
        let metadata = SourceMetadata(
            title: title,
            siteName: url.host,
            domain: url.host,
            thumbnailURL: nil,
            fetchStatus: .succeeded
        )
        return .init(metadata: metadata, resolvedKind: classifiedKind ?? .article)
    }

    private static func extractTitle(from html: String) -> String? {
        guard let start = html.range(of: "<title>", options: .caseInsensitive),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<html.endIndex)
        else { return nil }
        let raw = html[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : String(raw.prefix(200))
    }
}

enum URLMetadataResolverError: Error, Equatable {
    case httpFailure
    case unsupportedContentType
    case responseTooLarge
}

/// Deterministic resolver for tests and offline fixtures.
final class SuspendedURLMetadataResolver: URLMetadataResolving, @unchecked Sendable {
    private(set) var startedURLs: [URL] = []
    private var continuation: CheckedContinuation<URLMetadataResolveResult, Error>?

    func resolve(_ url: URL) async throws -> URLMetadataResolveResult {
        startedURLs.append(url)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with result: URLMetadataResolveResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
