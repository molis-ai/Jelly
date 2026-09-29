import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WeChatArticleAcquirerTests")
struct WeChatArticleAcquirerTests {
    /// Same shape as a real mp.weixin.qq.com page: huge scripts, the body in
    /// #js_content (with nested divs), metadata in JS variables and og tags.
    static let page = """
    <!DOCTYPE html><html><head>
    <meta property="og:title" content="慢下来做计划：一个&quot;三件事&quot;周报的试验" />
    <meta property="og:site_name" content="微信公众平台" />
    <title></title>
    <script>var noise = "\(String(repeating: "x", count: 5_000))";</script>
    </head><body>
    <div class="rich_media_area_primary">
      <h1 class="rich_media_title" id="activity-name">慢下来做计划</h1>
      <a id="js_name">试验笔记</a>
      <div class="rich_media_content" id="js_content" style="visibility: hidden;">
        <section><p>过去三个月，我把每周的周报压缩成三件事。</p></section>
        <div><div><p>第一件：只写对别人有影响的进展。</p></div></div>
        <p><img data-src="https://mmbiz.qpic.cn/x.jpg" /></p>
        <p>第二件：写清楚下周要别人配合的地方。</p>
        <p>第三件：留一句自己真正担心的事。</p>
      </div>
      <div id="js_pc_qr_code">微信扫一扫关注该公众号</div>
    </div>
    <script>
      var msg_title = '慢下来做计划\\x26nbsp;备用'.html(false);
      var nickname = htmlDecode("试验笔记");
      var ct = "1727000000";
    </script>
    </body></html>
    """

    @Test func onlyTheArticleBodyIsRead() throws {
        let url = try #require(URL(string: "https://mp.weixin.qq.com/s/AbCdEf123"))
        let batch = try WeChatArticleAcquirer.blocks(fromPage: Data(Self.page.utf8), baseURL: url)
        let texts = batch.blocks.map(\.text)
        #expect(batch.blocks.first?.role == .metadata)
        #expect(texts.first == "慢下来做计划：一个\"三件事\"周报的试验")
        #expect(texts.contains("过去三个月，我把每周的周报压缩成三件事。"))
        #expect(texts.contains("第一件：只写对别人有影响的进展。"))
        #expect(texts.contains("第三件：留一句自己真正担心的事。"))
        #expect(!texts.contains { $0.contains("扫一扫") })
        #expect(batch.coverage == .sufficient)
        #expect(batch.provenance.adapterIdentifier == "wechat-article")
        #expect(batch.provenance.diagnostics?.contains("试验笔记") == true)
        #expect(batch.provenance.diagnostics?.contains("2024-09-22") == true)
    }

    @Test func parserReadsMetadataAndBalancesNestedDivs() throws {
        let article = try WeChatArticleParser.parse(Self.page)
        #expect(article.account == "试验笔记")
        #expect(article.publishedAt == Date(timeIntervalSince1970: 1_727_000_000))
        #expect(article.contentHTML.contains("第三件"))
        #expect(!article.contentHTML.contains("扫一扫"))
        #expect(WeChatArticleParser.decodeJSEscapes("a\\x26b\\u4e2d") == "a&b中")
        #expect(WeChatArticleParser.decodeEntities("&#20013;&#x6587;&amp;&lt;") == "中文&<")
    }

    @Test func verificationAndRemovedPagesAreReportedHonestly() {
        let url = URL(string: "https://mp.weixin.qq.com/s/x")!
        #expect(throws: MaterialDigestPipelineError.restrictedSource) {
            try WeChatArticleAcquirer.blocks(fromPage: Data("<html><body>环境异常，完成验证后即可继续访问</body></html>".utf8), baseURL: url)
        }
        #expect(throws: MaterialDigestPipelineError.sourceUnavailable) {
            try WeChatArticleAcquirer.blocks(fromPage: Data("<html><body>该内容已被发布者删除</body></html>".utf8), baseURL: url)
        }
    }

    @Test func urlsRouteToTheDedicatedAdapter() throws {
        let short = try #require(URL(string: "https://mp.weixin.qq.com/s/FmD4TPrbD9jur-bS7_RcBw"))
        let long = try #require(URL(string: "https://mp.weixin.qq.com/s?__biz=MzI&mid=1&idx=1&sn=abc"))
        let home = try #require(URL(string: "https://mp.weixin.qq.com/"))
        #expect(SourceKindClassifier.classify(short) == .article)
        #expect(MaterialSourceResolver.descriptorKind(for: short) == .wechatArticle)
        #expect(MaterialSourceResolver.descriptorKind(for: long) == .wechatArticle)
        #expect(MaterialSourceResolver.descriptorKind(for: home) == .publicWebArticle)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_WECHAT"] == "1"))
    func livePublicArticlesAreExtracted() async throws {
        // Machines behind a fake-IP (198.18/15) TUN proxy fail Jelly's public-
        // address check for every source; this live check is about parsing.
        let acquirer = WeChatArticleAcquirer(client: MaterialHTTPClient(urlValidator: { $0.scheme == "https" }))
        for id in ["FmD4TPrbD9jur-bS7_RcBw", "OUyTh8W3-utxR37QFb76Wg"] {
            let url = try #require(URL(string: "https://mp.weixin.qq.com/s/\(id)"))
            let source = MaterialSource(
                inspirationID: InspirationID(),
                url: url,
                kind: .article,
                sourceChecksum: "live",
                sourceTitle: nil,
                descriptor: MaterialSourceDescriptor(kind: .wechatArticle)
            )
            guard case let .blocks(batch) = try await acquirer.acquire(source) else {
                Issue.record("expected blocks")
                continue
            }
            let bodyCharacters = batch.blocks.filter { $0.role == .body }.reduce(0) { $0 + $1.text.count }
            print("LIVE WECHAT \(id): \(batch.blocks.first?.text ?? "-") | \(batch.blocks.count) 块 | 正文 \(bodyCharacters) 字 | \(batch.provenance.diagnostics ?? "")")
            #expect(batch.coverage == .sufficient)
            #expect(bodyCharacters > 500)
        }
    }
}
