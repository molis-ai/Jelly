import Foundation
import WorkspaceDomain

struct HTMLMaterialExtractor: Sendable {
    private let maximumCharacters: Int
    private let maximumBlocks: Int

    init(
        maximumCharacters: Int = MaterialDigestContentLimits.maximumMaterialCharacters,
        maximumBlocks: Int = MaterialDigestContentLimits.maximumMaterialBlocks
    ) {
        self.maximumCharacters = maximumCharacters
        self.maximumBlocks = maximumBlocks
    }

    func extract(data: Data, baseURL: URL) throws -> MaterialBlockBatch {
        guard data.count <= maximumCharacters * 4 + 4 else {
            throw MaterialDigestPipelineError.contextTooLong
        }
        let html = String(decoding: data, as: UTF8.self)
        let cleaned = Self.removingNonContentElements(from: html)
        let candidate = Self.preferredContentRegion(in: cleaned)
        let imported: BlockHTMLImportResult
        do {
            imported = try BlockHTMLCodec.importHTML(
                candidate,
                checkedTaskCompletedAt: .distantPast
            )
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }

        var title = imported.document.blocks.first(where: { $0.kind == .heading1 })
            .map(Self.plainText)
            .map(Self.normalizedText)
            .flatMap { $0.isEmpty ? nil : $0 }
        if title == nil {
            title = Self.firstInnerHTML(tag: "title", in: cleaned)
                .flatMap(Self.decodedFragment)
                .map(Self.normalizedText)
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        var bodyTexts: [String] = []
        for block in imported.document.blocks {
            if block.kind == .heading1, title == Self.normalizedText(Self.plainText(block)) {
                continue
            }
            let text = Self.normalizedText(Self.plainText(block))
            guard MaterialTranscriptSemantics.hasSemanticContent(text) else { continue }
            if bodyTexts.last != text { bodyTexts.append(text) }
        }
        let totalCharacters = bodyTexts.reduce(title?.count ?? 0) { $0 + $1.count }
        guard totalCharacters <= maximumCharacters,
              bodyTexts.count + (title == nil ? 0 : 1) <= maximumBlocks
        else {
            throw MaterialDigestPipelineError.contextTooLong
        }

        var blocks: [MaterialBlock] = []
        if let title {
            blocks.append(MaterialBlock(
                id: MaterialBlockID(),
                role: .metadata,
                text: title,
                locator: .paragraph(index: 0),
                confidence: nil
            ))
        }
        blocks.append(contentsOf: bodyTexts.enumerated().map { index, text in
            MaterialBlock(
                id: MaterialBlockID(),
                role: .body,
                text: text,
                locator: .paragraph(index: index + 1),
                confidence: nil
            )
        })

        let coverage: MaterialCoverage
        if !bodyTexts.isEmpty {
            coverage = .sufficient
        } else if title != nil {
            coverage = .insufficient(code: .metadataOnly)
        } else {
            coverage = .insufficient(code: .empty)
        }
        return MaterialBlockBatch(
            blocks: blocks,
            coverage: coverage,
            provenance: MaterialAcquisitionProvenance(
                adapterIdentifier: "public-html",
                adapterVersion: "1",
                acquiredAt: Date(),
                diagnostics: baseURL.host
            )
        )
    }

    private static func removingNonContentElements(from html: String) -> String {
        ["script", "style", "nav", "footer", "header", "form", "noscript", "aside"]
            .reduce(html) { result, tag in
                replacingMatches(
                    in: result,
                    pattern: "(?is)<\\s*\(tag)\\b[^>]*>.*?<\\s*/\\s*\(tag)\\s*>",
                    with: "\n"
                )
            }
    }

    private static func preferredContentRegion(in html: String) -> String {
        for tag in ["article", "main"] {
            if let region = firstInnerHTML(tag: tag, in: html),
               MaterialTranscriptSemantics.hasSemanticContent(Self.stripTags(region)) {
                return region
            }
        }
        if let roleMain = firstMatch(
            pattern: "(?is)<([a-z][a-z0-9]*)\\b[^>]*\\brole\\s*=\\s*([\\\"'])?main\\2[^>]*>(.*?)<\\s*/\\s*\\1\\s*>",
            in: html,
            captureGroup: 3
        ) {
            return roleMain
        }
        return firstInnerHTML(tag: "body", in: html) ?? html
    }

    private static func firstInnerHTML(tag: String, in html: String) -> String? {
        firstMatch(
            pattern: "(?is)<\\s*\(tag)\\b[^>]*>(.*?)<\\s*/\\s*\(tag)\\s*>",
            in: html,
            captureGroup: 1
        )
    }

    private static func firstMatch(
        pattern: String,
        in text: String,
        captureGroup: Int
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: captureGroup), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    private static func decodedFragment(_ html: String) -> String? {
        guard let imported = try? BlockHTMLCodec.importHTML(
            "<p>\(html)</p>",
            checkedTaskCompletedAt: .distantPast
        ) else { return nil }
        let text = imported.document.blocks.map(plainText).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private static func stripTags(_ html: String) -> String {
        replacingMatches(in: html, pattern: "(?is)<[^>]+>", with: " ")
    }

    private static func plainText(_ block: DocumentBlock) -> String {
        block.inlineContent.spans.map(\.text).joined()
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
