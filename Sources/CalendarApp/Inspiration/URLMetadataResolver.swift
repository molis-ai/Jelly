import Foundation
import libxml2
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
        var data = Data()
        data.reserveCapacity(min(maxBytes, max(0, Int(http.expectedContentLength))))
        let checkStep = max(1, min(4_096, maxBytes))
        for try await byte in bytes {
            guard data.count < maxBytes else {
                if let title = Self.extractTitle(from: String(decoding: data, as: UTF8.self)) {
                    return Self.resolvedResult(url: url, title: title, classifiedKind: classifiedKind)
                }
                throw URLMetadataResolverError.responseTooLarge
            }
            data.append(byte)
            if data.count.isMultiple(of: checkStep),
               let title = Self.extractTitle(from: String(decoding: data, as: UTF8.self)) {
                return Self.resolvedResult(url: url, title: title, classifiedKind: classifiedKind)
            }
        }
        let html = String(decoding: data, as: UTF8.self)
        let title = Self.extractTitle(from: html) ?? url.host
        return Self.resolvedResult(url: url, title: title, classifiedKind: classifiedKind)
    }

    private static func resolvedResult(
        url: URL,
        title: String?,
        classifiedKind: ResolvedSourceKind?
    ) -> URLMetadataResolveResult {
        .init(
            metadata: SourceMetadata(
                title: MaterialSource.normalizedSourceTitle(title),
                siteName: url.host,
                domain: url.host,
                thumbnailURL: nil,
                fetchStatus: .succeeded
            ),
            resolvedKind: classifiedKind ?? .article
        )
    }

    private static func extractTitle(from html: String) -> String? {
        guard let start = html.range(of: "<title>", options: .caseInsensitive),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<html.endIndex)
        else { return nil }
        let raw = html[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return decodeHTMLEntities(String(raw))
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "&",
                  let semicolon = entityTerminator(in: text, after: index)
            else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }

            let bodyStart = text.index(after: index)
            let body = text[bodyStart..<semicolon]
            if let scalar = decodedEntity(body) {
                result.unicodeScalars.append(scalar)
                index = text.index(after: semicolon)
            } else {
                result.append("&")
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func entityTerminator(
        in text: String,
        after ampersand: String.Index
    ) -> String.Index? {
        var cursor = text.index(after: ampersand)
        for _ in 0..<32 {
            guard cursor < text.endIndex else { return nil }
            if text[cursor] == ";" { return cursor }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func decodedEntity(_ body: Substring) -> Unicode.Scalar? {
        guard !body.isEmpty else { return nil }
        if body.first == "#" {
            let numberStart = body.index(after: body.startIndex)
            let number = body[numberStart...]
            let isHex = number.first == "x" || number.first == "X"
            let digits = isHex ? number.dropFirst() : number[...]
            guard !digits.isEmpty,
                  let value = UInt32(digits, radix: isHex ? 16 : 10)
            else { return nil }
            return Unicode.Scalar(value)
        }

        var bytes = Array(body.utf8)
        bytes.append(0)
        return bytes.withUnsafeBufferPointer { buffer in
            guard let entity = htmlEntityLookup(buffer.baseAddress),
                  entity.pointee.value >= 0
            else { return nil }
            return Unicode.Scalar(UInt32(entity.pointee.value))
        }
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
