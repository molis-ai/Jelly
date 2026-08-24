import Foundation
import WorkspaceDomain

struct XiaohongshuMaterialAcquirer: Sendable {
    private static let maximumImages = 20
    private static let maximumImageBytes = 30_000_000

    let client: MaterialHTTPClient
    private let limits: MaterialHTTPLimits

    init(client: MaterialHTTPClient, limits: MaterialHTTPLimits = .init()) {
        self.client = client
        self.limits = limits
    }

    func acquire(_ source: MaterialSource) async throws -> MaterialCompositeAcquisition {
        guard case let .xiaohongshuNote(noteID) = source.descriptor.kind,
              let sourceURL = source.url
        else { throw MaterialDigestPipelineError.unsupportedSource }
        let page: (data: Data, response: HTTPURLResponse, finalURL: URL)
        do {
            page = try await client.get(
                sourceURL,
                headers: MaterialRequestHeaders.pageHeaders,
                maxBytes: limits.maxHTMLBytes
            )
        } catch MaterialHTTPClientError.restricted {
            throw MaterialDigestPipelineError.restrictedSource
        } catch MaterialHTTPClientError.tooLarge {
            throw MaterialDigestPipelineError.contextTooLong
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        guard SourceKindClassifier.xiaohongshuNoteID(for: page.finalURL) == noteID else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        let mime = page.response.mimeType?.lowercased()
        guard mime == "text/html" || mime == "application/xhtml+xml" else {
            throw MaterialDigestPipelineError.unsupportedSource
        }
        let html = String(decoding: page.data, as: UTF8.self)
        let payload: XiaohongshuNotePayload
        do {
            payload = try XiaohongshuPageParser.parse(html: html, expectedNoteID: noteID)
        } catch XiaohongshuPageParserError.missingInitialState {
            if looksRestricted(html) { throw MaterialDigestPipelineError.restrictedSource }
            throw MaterialDigestPipelineError.sourceUnavailable
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }

        let safeReferer = Self.withoutQueryOrFragment(page.finalURL)
        var issues: [MaterialCoverageIssue] = []
        let seedBlocks = Self.seedBlocks(payload)
        let images: [MaterialImageAsset]
        let remoteMedia: RemoteMediaAsset?
        let expectedAssetCount: Int
        switch payload.kind {
        case .image:
            expectedAssetCount = payload.images.count
            let selected = Array(payload.images.prefix(Self.maximumImages))
            if selected.count < payload.images.count { issues.append(.truncatedByLimit) }
            var downloaded: [MaterialImageAsset] = []
            for image in selected {
                try Task.checkCancellation()
                do {
                    let response = try await client.get(
                        image.url,
                        headers: MaterialRequestHeaders.pageHeaders(referer: safeReferer),
                        maxBytes: Self.maximumImageBytes
                    )
                    downloaded.append(MaterialImageAsset(index: image.index, data: response.data))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if !issues.contains(.inaccessibleAsset) { issues.append(.inaccessibleAsset) }
                }
            }
            images = downloaded
            remoteMedia = nil
        case .video:
            expectedAssetCount = 1
            images = []
            if let url = payload.videoCandidateURLs.first {
                remoteMedia = RemoteMediaAsset(
                    kind: .video,
                    url: url,
                    requestHeaders: [
                        "User-Agent": MaterialRequestHeaders.desktopUserAgent,
                        "Referer": safeReferer.absoluteString
                    ],
                    estimatedBytes: nil
                )
            } else {
                remoteMedia = nil
                issues.append(.inaccessibleAsset)
            }
        }
        return MaterialCompositeAcquisition(
            seedBlocks: seedBlocks,
            images: images,
            remoteMedia: remoteMedia,
            expectedAssetCount: expectedAssetCount,
            issues: issues,
            provenance: MaterialAcquisitionProvenance(
                adapterIdentifier: "xiaohongshu-public-page",
                adapterVersion: "1",
                acquiredAt: Date()
            )
        )
    }

    private static func seedBlocks(_ payload: XiaohongshuNotePayload) -> [MaterialBlock] {
        var blocks: [MaterialBlock] = []
        if let title = payload.title {
            blocks.append(MaterialBlock(
                id: MaterialBlockID(), role: .metadata, text: title,
                locator: .paragraph(index: 1), confidence: nil
            ))
        }
        if let body = payload.body {
            blocks.append(MaterialBlock(
                id: MaterialBlockID(), role: .body, text: body,
                locator: .paragraph(index: 1), confidence: nil
            ))
        }
        if !payload.tags.isEmpty {
            blocks.append(MaterialBlock(
                id: MaterialBlockID(), role: .metadata,
                text: "话题：" + payload.tags.map { "#\($0)" }.joined(separator: " "),
                locator: .paragraph(index: 2), confidence: nil
            ))
        }
        return blocks
    }

    private func looksRestricted(_ html: String) -> Bool {
        let text = html.lowercased()
        return text.contains("登录") || text.contains("login")
            || text.contains("captcha") || text.contains("验证")
    }

    private static func withoutQueryOrFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }
}
