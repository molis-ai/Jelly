import Foundation
import WorkspaceDomain

enum TextMaterialInput: Equatable, Sendable {
    case direct(text: String)
    case file(url: URL, utiIdentifier: String?)
}

protocol MaterialTextExtracting: Sendable {
    func extract(_ input: TextMaterialInput) async throws -> MaterialBlockBatch
}

struct TextMaterialExtractor: MaterialTextExtracting, Sendable {
    private let maximumCharacters: Int

    init(maximumCharacters: Int = MaterialDigestContentLimits.maximumMaterialCharacters) {
        self.maximumCharacters = maximumCharacters
    }

    func extract(_ input: TextMaterialInput) async throws -> MaterialBlockBatch {
        try Task.checkCancellation()
        let decoded = try decodedText(input)
        guard decoded.count <= maximumCharacters else {
            throw MaterialDigestPipelineError.contextTooLong
        }
        let paragraphs = Self.normalizedParagraphs(decoded)
            .filter(MaterialTranscriptSemantics.hasSemanticContent)
        let blocks = paragraphs.enumerated().map { index, paragraph in
            MaterialBlock(
                id: MaterialBlockID(),
                role: .body,
                text: paragraph,
                locator: .paragraph(index: index + 1),
                confidence: nil
            )
        }
        return MaterialBlockBatch(
            blocks: blocks,
            coverage: blocks.isEmpty ? .insufficient(code: .empty) : .sufficient,
            provenance: MaterialAcquisitionProvenance(
                adapterIdentifier: input.adapterIdentifier,
                adapterVersion: "1",
                acquiredAt: Date()
            )
        )
    }

    private func decodedText(_ input: TextMaterialInput) throws -> String {
        switch input {
        case let .direct(text):
            return text.contains("\0") ? "" : text
        case let .file(url, _):
            guard url.isFileURL else { throw MaterialDigestPipelineError.sourceUnavailable }
            if let byteCount = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               byteCount > maximumCharacters * 4 + 4 {
                throw MaterialDigestPipelineError.contextTooLong
            }
            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw MaterialDigestPipelineError.sourceUnavailable
            }
            guard data.count <= maximumCharacters * 4 + 4 else {
                throw MaterialDigestPipelineError.contextTooLong
            }
            return try Self.decode(data)
        }
    }

    private static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xef, 0xbb, 0xbf]) {
            guard let text = String(data: data.dropFirst(3), encoding: .utf8) else {
                throw MaterialDigestPipelineError.sourceUnavailable
            }
            return text
        }
        if data.starts(with: [0xff, 0xfe]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else {
                throw MaterialDigestPipelineError.sourceUnavailable
            }
            return text
        }
        if data.starts(with: [0xfe, 0xff]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else {
                throw MaterialDigestPipelineError.sourceUnavailable
            }
            return text
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        return text
    }

    private static func normalizedParagraphs(_ raw: String) -> [String] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [String] = []
        var lines: [String] = []
        func flush() {
            let paragraph = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            lines.removeAll(keepingCapacity: true)
        }
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                lines.append(line)
            }
        }
        flush()
        return paragraphs
    }
}

private extension TextMaterialInput {
    var adapterIdentifier: String {
        switch self {
        case .direct:
            return "direct-text"
        case .file:
            return "text-file"
        }
    }
}
