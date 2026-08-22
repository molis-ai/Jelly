import Foundation

public struct BlockHTMLDiagnostic: Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct BlockHTMLImportResult: Equatable, Sendable {
    public let document: BlockDocument
    public let diagnostics: [BlockHTMLDiagnostic]

    public init(document: BlockDocument, diagnostics: [BlockHTMLDiagnostic]) {
        self.document = document
        self.diagnostics = diagnostics
    }
}

public enum BlockHTMLCodec {
    public static func importHTML(
        _ html: String,
        checkedTaskCompletedAt: Date
    ) throws -> BlockHTMLImportResult {
        var parser = HTMLBlockParser(checkedTaskCompletedAt: checkedTaskCompletedAt)
        parser.consume(html)
        let result = parser.finish()
        try BlockDocumentValidator.validate(result.document)
        return result
    }

    public static func exportHTML(_ document: BlockDocument, title: String) throws -> String {
        try BlockDocumentValidator.validate(document)

        let body = document.blocks.map(exportBlock).joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapeHTML(title))</title>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func exportBlock(_ block: DocumentBlock) -> String {
        let inline = exportInline(block.inlineContent)
        switch block.kind {
        case .paragraph:
            return "<p>\(inline)</p>"
        case .heading1:
            return "<h1>\(inline)</h1>"
        case .heading2:
            return "<h2>\(inline)</h2>"
        case .heading3:
            return "<h3>\(inline)</h3>"
        case .bullet:
            return "<ul data-jelly-indent=\"\(block.indentLevel)\"><li data-jelly-kind=\"bullet\">\(inline)</li></ul>"
        case .ordered:
            return "<ol data-jelly-indent=\"\(block.indentLevel)\"><li data-jelly-kind=\"ordered\">\(inline)</li></ol>"
        case .task:
            let checked = block.taskState?.completedAt != nil ? " checked" : ""
            let completedAt = block.taskState?.completedAt.map {
                " data-jelly-completed-at=\"\($0.timeIntervalSince1970)\""
            } ?? ""
            let completion = block.taskState?.completionDescription.map {
                " data-jelly-completion-description=\"\(escapeAttribute($0))\""
            } ?? ""
            return "<ul data-jelly-indent=\"\(block.indentLevel)\"><li data-jelly-kind=\"task\"\(completion)><input type=\"checkbox\" disabled\(checked)\(completedAt)>\(inline)</li></ul>"
        case .quote:
            return "<blockquote>\(inline)</blockquote>"
        case .code:
            let info = block.codeInfoString.map { " data-jelly-info=\"\(escapeAttribute($0))\" class=\"language-\(escapeAttribute($0))\"" } ?? ""
            return "<pre><code\(info)>\(escapeHTML(block.inlineContent.plainText))</code></pre>"
        case .divider:
            return "<hr>"
        case .link:
            return "<p data-jelly-kind=\"link\">\(inline)</p>"
        }
    }

    private static func exportInline(_ content: InlineContent) -> String {
        content.spans.map { span in
            var text = escapeHTML(span.text).replacingOccurrences(of: "\n", with: "<br>")
            if span.marks.contains(.code) { text = "<code>\(text)</code>" }
            if span.marks.contains(.italic) { text = "<em>\(text)</em>" }
            if span.marks.contains(.bold) { text = "<strong>\(text)</strong>" }
            if let url = span.linkURL {
                text = "<a href=\"\(escapeAttribute(url.absoluteString))\">\(text)</a>"
            }
            return text
        }.joined()
    }
}

private struct HTMLBlockParser {
    private struct Builder {
        var kind: BlockKind
        var spans: [InlineSpan] = []
        var indentLevel = 0
        var taskState: TaskBlockState?
        var completionDescription: String?
        var codeInfoString: String?

        mutating func append(_ text: String, marks: Set<InlineMark>, linkURL: URL?, preserveWhitespace: Bool) {
            let decoded = decodeHTMLEntities(text)
            let normalized = preserveWhitespace ? decoded : collapseHTMLWhitespace(decoded)
            guard !normalized.isEmpty else { return }
            if let last = spans.indices.last,
               spans[last].marks == marks,
               spans[last].linkURL == linkURL {
                spans[last].text += normalized
            } else {
                spans.append(.init(text: normalized, marks: marks, linkURL: linkURL))
            }
        }
    }

    private let checkedTaskCompletedAt: Date
    private var blocks: [DocumentBlock] = []
    private var diagnostics: [BlockHTMLDiagnostic] = []
    private var current: Builder?
    private var listStack: [(kind: BlockKind, indent: Int)] = []
    private var marks: Set<InlineMark> = []
    private var markDepth: [InlineMark: Int] = [:]
    private var links: [URL?] = []
    private var skipDepth = 0
    private var tableDepth = 0
    private var tableText: [String] = []
    private var isPreformatted = false

    init(checkedTaskCompletedAt: Date) {
        self.checkedTaskCompletedAt = checkedTaskCompletedAt
    }

    mutating func consume(_ html: String) {
        let pattern = "(?s)<!--.*?-->|<![^>]*>|<[^>]*>|[^<]+"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in expression.matches(in: html, range: range) {
            guard let tokenRange = Range(match.range, in: html) else { continue }
            let token = String(html[tokenRange])
            if token.hasPrefix("<!--") || token.hasPrefix("<!") { continue }
            if token.hasPrefix("<") {
                consumeTag(token)
            } else {
                consumeText(token)
            }
        }
    }

    mutating func finish() -> BlockHTMLImportResult {
        finishCurrent()
        if tableDepth > 0 { finishTable() }
        return .init(document: BlockDocument(blocks: blocks), diagnostics: diagnostics)
    }

    private mutating func consumeTag(_ token: String) {
        let parsed = parseHTMLTag(token)
        guard !parsed.name.isEmpty else { return }

        if parsed.closing {
            if skipDepth > 0 {
                skipDepth -= 1
                return
            }
            if tableDepth > 0 {
                if parsed.name == "table" {
                    tableDepth -= 1
                    if tableDepth == 0 { finishTable() }
                } else if parsed.name == "td" || parsed.name == "th" {
                    tableText.append(" ")
                }
                return
            }
            closeTag(parsed.name)
            return
        }

        if skipDepth > 0 {
            let voidTags = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
            if !parsed.selfClosing, !voidTags.contains(parsed.name) { skipDepth += 1 }
            return
        }
        if ["head", "script", "style", "svg"].contains(parsed.name) {
            if !parsed.selfClosing { skipDepth = 1 }
            return
        }
        if tableDepth > 0 {
            if parsed.name == "table" { tableDepth += 1 }
            return
        }
        if parsed.name == "table" {
            finishCurrent()
            tableDepth = 1
            tableText = []
            diagnostics.append(.init(message: "表格结构暂不支持，已按正文保留"))
            return
        }

        switch parsed.name {
        case "h1": startBlock(.heading1, attributes: parsed.attributes)
        case "h2": startBlock(.heading2, attributes: parsed.attributes)
        case "h3", "h4", "h5", "h6": startBlock(.heading3, attributes: parsed.attributes)
        case "p", "div":
            let kind = parsed.attributes["data-jelly-kind"].flatMap(BlockKind.init(rawValue:)) ?? .paragraph
            startBlock(kind == .link ? .link : .paragraph, attributes: parsed.attributes)
        case "blockquote": startBlock(.quote, attributes: parsed.attributes)
        case "pre":
            startBlock(.code, attributes: parsed.attributes)
            isPreformatted = true
        case "ul", "ol":
            let kind: BlockKind = parsed.name == "ol" ? .ordered : .bullet
            let indent = parsed.attributes["data-jelly-indent"].flatMap(Int.init)
                ?? min(listStack.count, 3)
            listStack.append((kind, indent))
        case "li":
            finishCurrent()
            let jellyKind = parsed.attributes["data-jelly-kind"].flatMap(BlockKind.init(rawValue:))
            let list = listStack.last ?? (.bullet, 0)
            current = Builder(kind: jellyKind ?? list.kind, indentLevel: list.indent)
            current?.completionDescription = parsed.attributes["data-jelly-completion-description"]
        case "strong", "b": pushMark(.bold)
        case "em", "i": pushMark(.italic)
        case "code":
            if isPreformatted {
                current?.codeInfoString = parsed.attributes["data-jelly-info"]
                    ?? parsed.attributes["class"]?.split(separator: " ").first(where: { $0.hasPrefix("language-") }).map { String($0.dropFirst("language-".count)) }
            } else {
                pushMark(.code)
            }
        case "a": links.append(parsed.attributes["href"].flatMap(validHTMLURL))
        case "br": current?.append("\n", marks: marks, linkURL: links.last ?? nil, preserveWhitespace: true)
        case "hr":
            finishCurrent()
            blocks.append(.init(id: BlockID(), kind: .divider, inlineContent: .plain(""), taskState: nil, indentLevel: 0))
        case "input":
            if parsed.attributes["type"]?.lowercased() == "checkbox" {
                if current == nil {
                    let list = listStack.last ?? (.bullet, 0)
                    current = Builder(kind: .task, indentLevel: list.indent)
                }
                current?.kind = .task
                let completedAt = parsed.attributes.keys.contains("checked")
                    ? parsed.attributes["data-jelly-completed-at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? checkedTaskCompletedAt
                    : nil
                let completionDescription = current?.completionDescription
                current?.taskState = .init(
                    completedAt: completedAt,
                    completionDescription: completionDescription
                )
            }
        case "img":
            finishCurrent()
            if let alt = parsed.attributes["alt"], !alt.isEmpty {
                blocks.append(.init(id: BlockID(), kind: .paragraph, inlineContent: .plain(decodeHTMLEntities(alt)), taskState: nil, indentLevel: 0))
            }
            diagnostics.append(.init(message: "图片无法原样导入，已保留替代文字"))
        default: break
        }
    }

    private mutating func closeTag(_ name: String) {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "blockquote", "li": finishCurrent()
        case "pre":
            finishCurrent()
            isPreformatted = false
        case "ul", "ol":
            if !listStack.isEmpty { listStack.removeLast() }
        case "strong", "b": popMark(.bold)
        case "em", "i": popMark(.italic)
        case "code":
            if !isPreformatted { popMark(.code) }
        case "a":
            if !links.isEmpty { links.removeLast() }
        default: break
        }
    }

    private mutating func consumeText(_ token: String) {
        if skipDepth > 0 { return }
        if tableDepth > 0 {
            let text = collapseHTMLWhitespace(decodeHTMLEntities(token))
            if !text.isEmpty { tableText.append(text) }
            return
        }
        if current == nil {
            let text = collapseHTMLWhitespace(decodeHTMLEntities(token))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            current = Builder(kind: .paragraph)
        }
        current?.append(token, marks: marks, linkURL: links.last ?? nil, preserveWhitespace: isPreformatted)
    }

    private mutating func startBlock(_ kind: BlockKind, attributes: [String: String]) {
        finishCurrent()
        current = Builder(kind: kind)
        if kind == .code { current?.codeInfoString = attributes["data-jelly-info"] }
    }

    private mutating func finishCurrent() {
        guard var builder = current else { return }
        current = nil

        if builder.kind == .code {
            builder.spans = [.init(text: builder.spans.map(\.text).joined())]
        } else {
            trimStructuralWhitespace(&builder.spans)
        }
        if builder.spans.isEmpty { builder.spans = [.init(text: "")] }
        if builder.kind == .task {
            builder.taskState = .init(
                completedAt: builder.taskState?.completedAt,
                completionDescription: builder.completionDescription ?? builder.taskState?.completionDescription
            )
        }
        if builder.kind == .link,
           !builder.spans.contains(where: { $0.linkURL?.scheme != nil && $0.linkURL?.host != nil }) {
            builder.kind = .paragraph
            diagnostics.append(.init(message: "无效链接已按正文保留"))
        }
        let indent = builder.kind.supportsIndentation ? min(max(builder.indentLevel, 0), 3) : 0
        blocks.append(.init(
            id: BlockID(),
            kind: builder.kind,
            inlineContent: .init(spans: builder.spans),
            taskState: builder.kind == .task ? builder.taskState : nil,
            indentLevel: indent,
            codeInfoString: builder.kind == .code ? builder.codeInfoString : nil
        ))
    }

    private mutating func finishTable() {
        let text = tableText.joined().split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        if !text.isEmpty {
            blocks.append(.init(id: BlockID(), kind: .paragraph, inlineContent: .plain(text), taskState: nil, indentLevel: 0))
        }
        tableText = []
    }

    private mutating func pushMark(_ mark: InlineMark) {
        markDepth[mark, default: 0] += 1
        marks.insert(mark)
    }

    private mutating func popMark(_ mark: InlineMark) {
        let depth = max((markDepth[mark] ?? 1) - 1, 0)
        markDepth[mark] = depth
        if depth == 0 { marks.remove(mark) }
    }
}

private struct ParsedHTMLTag {
    let name: String
    let attributes: [String: String]
    let closing: Bool
    let selfClosing: Bool
}

private func parseHTMLTag(_ token: String) -> ParsedHTMLTag {
    var body = token.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
    let closing = body.hasPrefix("/")
    if closing { body = String(body.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
    let selfClosing = body.hasSuffix("/")
    if selfClosing { body = String(body.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
    let name = body.split(whereSeparator: \Character.isWhitespace).first.map { $0.lowercased() } ?? ""
    let attributeBody = String(body.dropFirst(name.count))
    var attributes: [String: String] = [:]
    let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+)))?"#
    if let expression = try? NSRegularExpression(pattern: pattern) {
        let range = NSRange(attributeBody.startIndex..<attributeBody.endIndex, in: attributeBody)
        for match in expression.matches(in: attributeBody, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: attributeBody) else { continue }
            let key = attributeBody[keyRange].lowercased()
            var value = ""
            for index in 2...4 where match.range(at: index).location != NSNotFound {
                if let valueRange = Range(match.range(at: index), in: attributeBody) {
                    value = String(attributeBody[valueRange])
                    break
                }
            }
            attributes[key] = decodeHTMLEntities(value)
        }
    }
    return .init(name: name, attributes: attributes, closing: closing, selfClosing: selfClosing)
}

private func validHTMLURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host != nil else { return nil }
    return url
}

private func collapseHTMLWhitespace(_ text: String) -> String {
    text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

private func trimStructuralWhitespace(_ spans: inout [InlineSpan]) {
    while let first = spans.first, first.text.isEmpty { spans.removeFirst() }
    while let last = spans.last, last.text.isEmpty { spans.removeLast() }
    if !spans.isEmpty {
        spans[0].text = spans[0].text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
        let last = spans.index(before: spans.endIndex)
        spans[last].text = spans[last].text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
    }
    spans.removeAll(where: { $0.text.isEmpty })
}

private func decodeHTMLEntities(_ text: String) -> String {
    var decoded = text
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&amp;", with: "&")
    let pattern = #"&#(x[0-9A-Fa-f]+|[0-9]+);"#
    if let expression = try? NSRegularExpression(pattern: pattern) {
        let matches = expression.matches(in: decoded, range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)).reversed()
        for match in matches {
            guard let whole = Range(match.range(at: 0), in: decoded),
                  let valueRange = Range(match.range(at: 1), in: decoded) else { continue }
            let raw = String(decoded[valueRange])
            let value = raw.hasPrefix("x")
                ? UInt32(raw.dropFirst(), radix: 16)
                : UInt32(raw, radix: 10)
            if let value, let scalar = UnicodeScalar(value) {
                decoded.replaceSubrange(whole, with: String(scalar))
            }
        }
    }
    return decoded
}

private func escapeHTML(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func escapeAttribute(_ text: String) -> String {
    escapeHTML(text).replacingOccurrences(of: "'", with: "&#39;")
}

public extension InlineContent {
    var plainText: String { spans.map(\.text).joined() }
}
