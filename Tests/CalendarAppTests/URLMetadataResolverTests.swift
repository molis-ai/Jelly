import Foundation
import Testing
@testable import CalendarApp

@Suite("URLMetadataResolverTests", .serialized)
struct URLMetadataResolverTests {
    @Test func rejectsNonHTMLResponsesInsteadOfInventingArticleMetadata() async throws {
        let resolver = makeResolver(
            contentType: "application/octet-stream",
            data: Data("not html".utf8),
            maxBytes: 64
        )

        do {
            _ = try await resolver.resolve(URL(string: "https://example.com/file")!)
            Issue.record("non-HTML response was accepted")
        } catch {}
    }

    @Test func rejectsAResponseThatExceedsTheConfiguredByteLimit() async throws {
        let resolver = makeResolver(
            contentType: "text/html; charset=utf-8",
            data: Data(repeating: 65, count: 65),
            maxBytes: 64
        )

        await #expect(throws: URLMetadataResolverError.responseTooLarge) {
            _ = try await resolver.resolve(URL(string: "https://example.com/large")!)
        }
    }

    @Test func acceptsCompleteTitleBeforeTheByteLimitEvenWhenDeclaredBodyIsLarger() async throws {
        let prefix = "<html><head><title>B站大型页面</title></head><body>"
        let body = prefix + String(repeating: "x", count: 512)
        let resolver = makeResolver(
            contentType: "text/html; charset=utf-8",
            data: Data(body.utf8),
            maxBytes: 64
        )

        let result = try await resolver.resolve(
            URL(string: "https://www.bilibili.com/video/BV1hgEj6LEVh/")!
        )

        #expect(result.metadata.title == "B站大型页面")
        #expect(result.metadata.fetchStatus == .succeeded)
        #expect(result.resolvedKind == .video)
    }

    @Test func rejectsWhenTitleClosingTagFallsOutsideTheByteLimit() async throws {
        let html = "<html><head><title>" + String(repeating: "y", count: 80) + "</title></head></html>"
        let resolver = makeResolver(
            contentType: "text/html; charset=utf-8",
            data: Data(html.utf8),
            maxBytes: 64
        )

        await #expect(throws: URLMetadataResolverError.responseTooLarge) {
            _ = try await resolver.resolve(
                URL(string: "https://www.bilibili.com/video/BV1hgEj6LEVh/")!
            )
        }
    }

    @Test func successfulBilibiliHTMLKeepsVideoKind() async throws {
        let resolver = makeHTMLResolver(title: "B站视频标题")
        let result = try await resolver.resolve(
            URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!
        )
        #expect(result.resolvedKind == .video)
        #expect(result.metadata.title == "B站视频标题")
        #expect(result.metadata.fetchStatus == .succeeded)
    }

    @Test func successfulXiaoyuzhouHTMLKeepsAudioKind() async throws {
        let resolver = makeHTMLResolver(title: "小宇宙单集")
        let result = try await resolver.resolve(
            URL(string: "https://www.xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e")!
        )
        #expect(result.resolvedKind == .audio)
        #expect(result.metadata.title == "小宇宙单集")
        #expect(result.metadata.fetchStatus == .succeeded)
    }

    @Test func successfulOrdinaryHTMLRemainsArticle() async throws {
        let resolver = makeHTMLResolver(title: "普通文章")
        let result = try await resolver.resolve(URL(string: "https://example.com/post")!)
        #expect(result.resolvedKind == .article)
        #expect(result.metadata.title == "普通文章")
    }

    @Test func decodesHTMLEntitiesInSourceTitle() async throws {
        let resolver = makeHTMLResolver(
            title: "Claude &amp; Anthropic &#x2014; Tom&#39;s Notes"
        )
        let result = try await resolver.resolve(URL(string: "https://example.com/post")!)

        #expect(result.metadata.title == "Claude & Anthropic — Tom's Notes")
    }

    @Test func decodesNamedAndUppercaseHexHTMLEntitiesInSourceTitle() async throws {
        let resolver = makeHTMLResolver(
            title: "Claude &eacute;lan &mdash; &#X2014; Anthropic"
        )
        let result = try await resolver.resolve(URL(string: "https://example.com/post")!)

        #expect(result.metadata.title == "Claude élan — — Anthropic")
    }

    @Test func decodesHTMLEntitiesOnlyOnce() async throws {
        let resolver = makeHTMLResolver(title: "Tom&amp;#39;s Notes")
        let result = try await resolver.resolve(URL(string: "https://example.com/post")!)

        #expect(result.metadata.title == "Tom&#39;s Notes")
    }

    @Test func aPlainAmpersandDoesNotHideALaterEntity() async throws {
        let resolver = makeHTMLResolver(title: "R&D &amp; AI")
        let result = try await resolver.resolve(URL(string: "https://example.com/post")!)

        #expect(result.metadata.title == "R&D & AI")
    }

    @Test func titleEntityDecoderNeverInterpretsEmbeddedHTMLResources() async throws {
        let rawTitle = "<img src='http://127.0.0.1:9/private-title-probe.gif'>Claude &amp; Anthropic"
        let resolver = makeHTMLResolver(title: rawTitle)
        let result = try await resolver.resolve(URL(string: "https://example.com/post")!)

        #expect(result.metadata.title == "<img src='http://127.0.0.1:9/private-title-probe.gif'>Claude & Anthropic")
    }

    @Test func normalizesAndScalarCapsResolvedSourceTitle() async throws {
        let rawTitle = "  A" + String(repeating: "\u{0301}", count: 400) + "\nClaude\tCode  "
        let resolver = makeHTMLResolver(title: rawTitle)
        let result = try await resolver.resolve(URL(string: "https://example.com/post")!)
        let title = try #require(result.metadata.title)

        #expect(title.unicodeScalars.count <= 200)
        #expect(!title.contains("\n"))
        #expect(!title.contains("\t"))
    }

    @Test func keepsMissingTitleNilWhenHostlessHTMLHasNoTitle() async throws {
        let resolver = makeResolver(
            contentType: "text/html; charset=utf-8",
            data: Data("<html><head></head><body>no title</body></html>".utf8),
            maxBytes: 256_000
        )

        let result = try await resolver.resolve(URL(string: "app:untitled")!)

        #expect(result.metadata.title == nil)
    }

    private func makeResolver(
        contentType: String,
        data: Data,
        maxBytes: Int,
        contentLength: Int? = nil
    ) -> URLMetadataResolver {
        URLMetadataURLProtocol.fixture = .init(
            contentType: contentType,
            data: data,
            contentLength: contentLength
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLMetadataURLProtocol.self]
        return URLMetadataResolver(maxBytes: maxBytes, configuration: configuration)
    }

    private func makeHTMLResolver(title: String) -> URLMetadataResolver {
        makeResolver(
            contentType: "text/html; charset=utf-8",
            data: Data("<html><head><title>\(title)</title></head></html>".utf8),
            maxBytes: 256_000
        )
    }
}

private final class URLMetadataURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture: Sendable {
        let contentType: String
        let data: Data
        let contentLength: Int?

        init(contentType: String, data: Data, contentLength: Int? = nil) {
            self.contentType = contentType
            self.data = data
            self.contentLength = contentLength
        }
    }

    nonisolated(unsafe) static var fixture = Fixture(contentType: "text/html", data: Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture = Self.fixture
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": fixture.contentType,
                "Content-Length": String(fixture.contentLength ?? fixture.data.count)
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
