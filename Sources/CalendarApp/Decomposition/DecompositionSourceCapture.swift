import CryptoKit
import Foundation
import WorkspaceDomain

enum DecompositionSourceCaptureError: Error, Equatable {
    case emptySource
    case crossBlockSelection
    case blockSelectionUnsupported
    case invalidSelection
}

enum DecompositionSourceCapture {
    private static let checksumVersion = "decomposition-source-v1"

    static func capture(
        note: Note,
        workspaceRevision: Int64,
        selection: BlockEditorSelection
    ) throws -> DecompositionSourceSnapshot {
        let noteChecksum = try WorkspaceChecksum.noteSnapshotChecksum(note)
        let resolved = try resolve(selection, in: note.document)
        let normalizedText = resolved.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw DecompositionSourceCaptureError.emptySource
        }
        return DecompositionSourceSnapshot(
            noteID: note.id,
            noteRevision: note.revision,
            workspaceRevision: workspaceRevision,
            sourceBlockID: resolved.blockID,
            selectedRange: resolved.range,
            normalizedText: normalizedText,
            noteChecksum: noteChecksum,
            sourceChecksum: sourceChecksum(
                noteChecksum: noteChecksum,
                sourceBlockID: resolved.blockID,
                selectedRange: resolved.range,
                normalizedText: normalizedText
            )
        )
    }

    private struct ResolvedSource {
        let blockID: BlockID?
        let range: DecompositionSourceSnapshot.TextRange?
        let text: String
    }

    private static func resolve(
        _ selection: BlockEditorSelection,
        in document: BlockDocument
    ) throws -> ResolvedSource {
        switch selection {
        case .blocks:
            throw DecompositionSourceCaptureError.blockSelectionUnsupported
        case let .text(anchor, focus, _, _):
            if anchor == focus {
                try validateCollapsedCaret(anchor, in: document)
                return ResolvedSource(blockID: nil, range: nil, text: wholeNotePlainText(document))
            }
            guard anchor.blockID == focus.blockID else {
                throw DecompositionSourceCaptureError.crossBlockSelection
            }
            let block = try block(id: anchor.blockID, in: document)
            let text = plainText(block)
            let lower = min(anchor.graphemeOffset, focus.graphemeOffset)
            let upper = max(anchor.graphemeOffset, focus.graphemeOffset)
            let selected = try graphemeSlice(text, lower: lower, upper: upper)
            return ResolvedSource(
                blockID: block.id,
                range: .init(blockID: block.id, lowerGraphemeOffset: lower, upperGraphemeOffset: upper),
                text: selected
            )
        }
    }

    private static func validateCollapsedCaret(
        _ position: BlockTextPosition,
        in document: BlockDocument
    ) throws {
        let block = try block(id: position.blockID, in: document)
        let text = plainText(block)
        guard position.graphemeOffset >= 0, position.graphemeOffset <= text.count else {
            throw DecompositionSourceCaptureError.invalidSelection
        }
    }

    private static func block(id: BlockID, in document: BlockDocument) throws -> DocumentBlock {
        guard let block = document.blocks.first(where: { $0.id == id }) else {
            throw DecompositionSourceCaptureError.invalidSelection
        }
        return block
    }

    private static func wholeNotePlainText(_ document: BlockDocument) -> String {
        document.blocks.map { block in
            block.kind == .divider ? "" : plainText(block)
        }.joined(separator: "\n")
    }

    private static func plainText(_ block: DocumentBlock) -> String {
        block.inlineContent.spans.map(\.text).joined()
    }

    private static func graphemeSlice(_ text: String, lower: Int, upper: Int) throws -> String {
        guard lower >= 0, upper >= lower, upper <= text.count else {
            throw DecompositionSourceCaptureError.invalidSelection
        }
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(text.startIndex, offsetBy: upper)
        return String(text[start..<end])
    }

    private static func sourceChecksum(
        noteChecksum: String,
        sourceBlockID: BlockID?,
        selectedRange: DecompositionSourceSnapshot.TextRange?,
        normalizedText: String
    ) -> String {
        var data = Data()
        appendLengthPrefixed(Data(checksumVersion.utf8), to: &data)
        appendLengthPrefixed(Data(noteChecksum.utf8), to: &data)
        appendLengthPrefixed(Data((sourceBlockID?.rawValue.uuidString ?? "").utf8), to: &data)
        if let selectedRange {
            let encoded = "\(selectedRange.lowerGraphemeOffset):\(selectedRange.upperGraphemeOffset)"
            appendLengthPrefixed(Data(encoded.utf8), to: &data)
        } else {
            appendLengthPrefixed(Data(), to: &data)
        }
        appendLengthPrefixed(Data(normalizedText.utf8), to: &data)
        return sha256Hex(data)
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
