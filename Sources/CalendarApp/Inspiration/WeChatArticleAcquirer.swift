import Foundation
import WorkspaceDomain

/// Public 公众号 articles (mp.weixin.qq.com/s…). The page is several MB of
/// scripts around one `#js_content` element; only that element is read.
enum WeChatArticleParser {
    struct Article: Equatable, Sendable {
        var title: String?
        var account: String?
        var publishedAt: Date?
        var contentHTML: String
    }

    enum Failure: Error, Equatable {
        case verificationRequired
        case removed
        case notAnArticle
    }

    static func isArticleURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "mp.weixin.qq.com"
        else { return false }
        let path = url.path.lowercased()
        return path == "/s" || path.hasPrefix("/s/")
    }

    static func parse(_ html: String) throws -> Article {
        guard let content = contentHTML(in: html) else {
            if html.contains("环境异常") || html.contains("完成验证") || html.contains("去验证") {
                throw Failure.verificationRequired
            }
            if html.contains("已被发布者删除") || html.contains("违规无法查看") || html.contains("内容已被删除") {
                throw Failure.removed
            }
            throw Failure.notAnArticle
        }
        let title = metaContent("og:title", in: html)
            ?? jsString(after: "var msg_title = ", in: html)
            ?? firstCapture("(?is)<h1[^>]*id=\"activity-name\"[^>]*>(.*?)</h1>", in: html).map(stripTags)
        let account = jsHTMLDecodeArgument(after: "var nickname = ", in: html)
            ?? firstCapture("(?is)<a[^>]*id=\"js_name\"[^>]*>(.*?)</a>", in: html).map(stripTags)
        let published = firstCapture("var ct = \"(\\d{9,11})\"", in: html)
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        return Article(
            title: title.map(clean).flatMap { $0.isEmpty ? nil : $0 },
            account: account.map(clean).flatMap { $0.isEmpty ? nil : $0 },
            publishedAt: published,
            contentHTML: content
        )
    }

    /// Inner HTML of `<div id="js_content">`, balancing nested divs.
    static func contentHTML(in html: String) -> String? {
        guard let marker = html.range(of: "id=\"js_content\""),
              let tagEnd = html[marker.upperBound...].firstIndex(of: ">")
        else { return nil }
        let bodyStart = html.index(after: tagEnd)
        guard let expression = try? NSRegularExpression(pattern: "(?i)<div\\b|</div\\s*>") else { return nil }
        let nsHTML = html as NSString
        let searchRange = NSRange(bodyStart..<html.endIndex, in: html)
        var depth = 1
        for match in expression.matches(in: html, range: searchRange) {
            let token = nsHTML.substring(with: match.range).lowercased()
            depth += token.hasPrefix("</") ? -1 : 1
            if depth == 0, let end = Range(match.range, in: html)?.lowerBound {
                let inner = String(html[bodyStart..<end])
                return inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : inner
            }
        }
        return nil
    }

    /// The wrapper handed to the shared HTML extractor: title as heading,
    /// then the article body; images and scripts inside are dropped there.
    static func extractorDocument(for article: Article) -> String {
        var parts = ["<html><body><article>"]
        if let title = article.title {
            parts.append("<h1>\(escape(title))</h1>")
        }
        parts.append(article.contentHTML)
        parts.append("</article></body></html>")
        return parts.joined(separator: "\n")
    }

    private static func metaContent(_ property: String, in html: String) -> String? {
        firstCapture("(?i)<meta\\s+property=\"\(NSRegularExpression.escapedPattern(for: property))\"\\s+content=\"([^\"]*)\"", in: html)
            .map(decodeEntities)
    }

    private static func jsString(after prefix: String, in html: String) -> String? {
        firstCapture(NSRegularExpression.escapedPattern(for: prefix) + "'((?:\\\\.|[^'\\\\])*)'", in: html)
            .map(decodeJSEscapes)
            .map(decodeEntities)
    }

    private static func jsHTMLDecodeArgument(after prefix: String, in html: String) -> String? {
        firstCapture(NSRegularExpression.escapedPattern(for: prefix) + "htmlDecode\\(\"((?:\\\\.|[^\"\\\\])*)\"\\)", in: html)
            .map(decodeJSEscapes)
            .map(decodeEntities)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    static func decodeJSEscapes(_ text: String) -> String {
        var result = ""
        var iterator = Array(text).makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "x":
                let hex = String([iterator.next(), iterator.next()].compactMap { $0 })
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                }
            case "u":
                let hex = String((0..<4).compactMap { _ in iterator.next() })
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                }
            case "n": result.append("\n")
            case "t": result.append("\t")
            default: result.append(next)
            }
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let named = ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        if let expression = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = result as NSString
            var output = ""
            var cursor = 0
            for match in expression.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let isHex = ns.substring(with: match.range(at: 1)) == "x"
                let digits = ns.substring(with: match.range(at: 2))
                if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    output.unicodeScalars.append(scalar)
                }
                cursor = match.range.location + match.range.length
            }
            output += ns.substring(from: cursor)
            result = output
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func stripTags(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct WeChatArticleAcquirer: MaterialAcquiring {
    static let maximumPageBytes = 8_000_000
    let client: MaterialHTTPClient
    let extractor: HTMLMaterialExtractor

    init(client: MaterialHTTPClient, extractor: HTMLMaterialExtractor = HTMLMaterialExtractor()) {
        self.client = client
        self.extractor = extractor
    }

    func acquire(_ source: MaterialSource) async throws -> MaterialAcquisition {
        guard let url = source.url, WeChatArticleParser.isArticleURL(url) else {
            throw MaterialDigestPipelineError.unsupportedSource
        }
        let response: (data: Data, response: HTTPURLResponse, finalURL: URL)
        do {
            response = try await client.get(url, headers: MaterialRequestHeaders.pageHeaders, maxBytes: Self.maximumPageBytes)
        } catch MaterialHTTPClientError.restricted {
            throw MaterialDigestPipelineError.restrictedSource
        } catch MaterialHTTPClientError.tooLarge {
            throw MaterialDigestPipelineError.contextTooLong
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        return .blocks(try Self.blocks(fromPage: response.data, baseURL: response.finalURL, extractor: extractor))
    }

    static func blocks(
        fromPage data: Data,
        baseURL: URL,
        extractor: HTMLMaterialExtractor = HTMLMaterialExtractor()
    ) throws -> MaterialBlockBatch {
        let article: WeChatArticleParser.Article
        do {
            article = try WeChatArticleParser.parse(String(decoding: data, as: UTF8.self))
        } catch WeChatArticleParser.Failure.verificationRequired {
            throw MaterialDigestPipelineError.restrictedSource
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        let batch = try extractor.extract(
            data: Data(WeChatArticleParser.extractorDocument(for: article).utf8),
            baseURL: baseURL
        )
        var diagnostics = ["mp.weixin.qq.com"]
        if let account = article.account { diagnostics.append(account) }
        if let date = article.publishedAt {
            diagnostics.append(date.formatted(.iso8601.year().month().day()))
        }
        return MaterialBlockBatch(
            blocks: batch.blocks,
            coverage: batch.coverage,
            provenance: MaterialAcquisitionProvenance(
                adapterIdentifier: "wechat-article",
                adapterVersion: "1",
                acquiredAt: batch.provenance.acquiredAt,
                diagnostics: diagnostics.joined(separator: " · ")
            )
        )
    }
}
