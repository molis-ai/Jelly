import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("XiaohongshuMaterialAcquirerTests", .serialized)
struct XiaohongshuMaterialAcquirerTests {
    @Test func videoPageUsesCookieFreeRequestAndReturnsCompositeMaterial() async throws {
        XHSAcquirerURLProtocol.reset()
        let pageURL = "https://www.xiaohongshu.com/explore/video-note-id"
        XHSAcquirerURLProtocol.setHTML(url: pageURL, html: noteHTML(
            id: "video-note-id",
            type: "video",
            images: [],
            videoURL: "https://media.example/video.mp4"
        ))
        let acquisition = try await acquirer().acquire(source(
            pageURL,
            noteID: "video-note-id"
        ))

        #expect(acquisition.seedBlocks.map(\.role) == [.metadata, .body, .metadata])
        #expect(acquisition.seedBlocks.map(\.text) == [
            "页面标题", "公开正文", "话题：#效率 #学习"
        ])
        #expect(acquisition.images.isEmpty)
        #expect(acquisition.remoteMedia?.kind == .video)
        #expect(acquisition.remoteMedia?.url.absoluteString == "https://media.example/video.mp4")
        #expect(acquisition.remoteMedia?.requestHeaders["Cookie"] == nil)
        #expect(acquisition.remoteMedia?.requestHeaders["Referer"] == pageURL)
        let pageRequest = try #require(XHSAcquirerURLProtocol.request(for: pageURL))
        #expect(pageRequest.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(pageRequest.value(forHTTPHeaderField: "Referer") == nil)
    }

    @Test func imagePageDownloadsAllPublicImagesInOrder() async throws {
        XHSAcquirerURLProtocol.reset()
        let pageURL = "https://www.xiaohongshu.com/explore/image-note-id"
        let imageURLs = [
            "https://img.example/1.jpg",
            "https://img.example/2.jpg",
            "https://img.example/3.jpg"
        ]
        XHSAcquirerURLProtocol.setHTML(url: pageURL, html: noteHTML(
            id: "image-note-id",
            type: "normal",
            images: imageURLs,
            videoURL: nil
        ))
        for (index, url) in imageURLs.enumerated() {
            XHSAcquirerURLProtocol.setData(
                url: url,
                contentType: "image/jpeg",
                data: Data([UInt8(index + 1)])
            )
        }

        let acquisition = try await acquirer().acquire(source(
            pageURL,
            noteID: "image-note-id"
        ))

        #expect(acquisition.images.map(\.index) == [1, 2, 3])
        #expect(acquisition.images.map(\.data) == [Data([1]), Data([2]), Data([3])])
        #expect(acquisition.remoteMedia == nil)
        #expect(acquisition.expectedAssetCount == 3)
        #expect(acquisition.seedBlocks.first?.role == .metadata)
    }

    @Test func restrictedPageMapsToRestrictedSource() async {
        XHSAcquirerURLProtocol.reset()
        let pageURL = "https://www.xiaohongshu.com/explore/restricted-note"
        XHSAcquirerURLProtocol.set(
            url: pageURL,
            status: 403,
            contentType: "text/html",
            data: Data()
        )
        await #expect(throws: MaterialDigestPipelineError.restrictedSource) {
            _ = try await acquirer().acquire(source(pageURL, noteID: "restricted-note"))
        }
    }

    private func acquirer() -> XiaohongshuMaterialAcquirer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XHSAcquirerURLProtocol.self]
        return XiaohongshuMaterialAcquirer(
            client: MaterialHTTPClient(configuration: configuration, urlValidator: { _ in true })
        )
    }

    private func source(_ raw: String, noteID: String) -> MaterialSource {
        MaterialSource(
            inspirationID: InspirationID(),
            url: URL(string: raw)!,
            kind: .socialPost,
            sourceChecksum: "checksum",
            descriptor: MaterialSourceDescriptor(kind: .xiaohongshuNote(noteID: noteID))
        )
    }

    private func noteHTML(
        id: String,
        type: String,
        images: [String],
        videoURL: String?
    ) -> String {
        let imageJSON = images.map { #"{"url":"\#($0)"}"# }.joined(separator: ",")
        let videoJSON = videoURL.map { #"{"masterUrl":"\#($0)"}"# } ?? "null"
        return """
        <script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"\(id)":{"note":{
          "noteId":"\(id)","type":"\(type)","title":"页面标题","desc":"公开正文",
          "tagList":[{"name":"效率"},{"name":"学习"}],
          "imageList":[\(imageJSON)],"video":\(videoJSON)
        }}}}};</script>
        """
    }
}

private final class XHSAcquirerURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Fixture: Sendable {
        let status: Int
        let contentType: String
        let data: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: Fixture] = [:]
    nonisolated(unsafe) private static var requests: [String: URLRequest] = [:]

    static func reset() {
        lock.lock()
        fixtures = [:]
        requests = [:]
        lock.unlock()
    }

    static func setHTML(url: String, html: String) {
        set(url: url, status: 200, contentType: "text/html", data: Data(html.utf8))
    }

    static func setData(url: String, contentType: String, data: Data) {
        set(url: url, status: 200, contentType: contentType, data: data)
    }

    static func set(url: String, status: Int, contentType: String, data: Data) {
        lock.lock()
        fixtures[url] = Fixture(status: status, contentType: contentType, data: data)
        lock.unlock()
    }

    static func request(for url: String) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests[url]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requests[url.absoluteString] = request
        let fixture = Self.fixtures[url.absoluteString]
        Self.lock.unlock()
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": fixture.contentType,
                "Content-Length": String(fixture.data.count)
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
