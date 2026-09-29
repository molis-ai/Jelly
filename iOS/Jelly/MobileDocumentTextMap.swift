import Foundation
import WorkspaceDomain

/// TextKit offsets are UTF-16; the domain reducer addresses graphemes within
/// stable BlockIDs. Separators belong to neither block and are mapped to the
/// previous end / next start so selecting a newline really selects a boundary.
struct MobileDocumentTextMap {
    struct Entry {
        let block: DocumentBlock
        let range: NSRange
        let text: String
    }
    let entries: [Entry]
    let text: String

    init(_ document: BlockDocument) {
        var entries: [Entry] = []
        var text = ""
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { text += "\n" }
            let displayed = block.kind == .divider ? "\u{FFFC}" : block.inlineContent.spans.map(\.text).joined()
            entries.append(.init(block: block, range: NSRange(location: text.utf16.count, length: displayed.utf16.count), text: displayed))
            text += displayed
        }
        self.entries = entries
        self.text = text
    }

    func position(at offset: Int) -> BlockTextPosition? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        guard let entry = entries.first(where: { offset <= NSMaxRange($0.range) }) ?? entries.last else { return nil }
        if entry.block.kind == .divider { return .init(blockID: entry.block.id, graphemeOffset: 0) }
        let local = max(0, offset - entry.range.location)
        // UIKit can report an interior UTF-16 boundary while adjusting a
        // selection. Snap backwards to a whole extended grapheme, never split
        // emoji, combining accents, or a Chinese IME commit.
        var units = 0
        var count = 0
        for character in entry.text {
            let length = String(character).utf16.count
            if units + length > local { break }
            units += length
            count += 1
        }
        return .init(blockID: entry.block.id, graphemeOffset: count)
    }

    func offset(of position: BlockTextPosition) -> Int? {
        guard let entry = entries.first(where: { $0.block.id == position.blockID }) else { return nil }
        guard position.graphemeOffset >= 0 else { return nil }
        if entry.block.kind == .divider { return entry.range.location }
        guard position.graphemeOffset <= entry.text.count else { return nil }
        return entry.range.location + entry.text.prefix(position.graphemeOffset).utf16.count
    }

    func selection(in range: NSRange, attributes: BlockTypingAttributes) -> BlockEditorSelection? {
        if let divider = entries.first(where: { $0.block.kind == .divider && $0.range == range }) {
            return .blocks(anchor: divider.block.id, focus: divider.block.id)
        }
        guard range.location != NSNotFound, range.length >= 0,
              let anchor = position(at: range.location), let focus = position(at: NSMaxRange(range)) else { return nil }
        return .text(anchor: anchor, focus: focus, preferredColumn: nil, typingAttributes: attributes)
    }

    func range(of selection: BlockEditorSelection) -> NSRange? {
        switch selection {
        case let .text(anchor, focus, _, _):
            guard let start = offset(of: anchor), let end = offset(of: focus) else { return nil }
            return NSRange(location: min(start, end), length: abs(end - start))
        case let .blocks(anchor, focus):
            guard let ai = entries.firstIndex(where: { $0.block.id == anchor }),
                  let fi = entries.firstIndex(where: { $0.block.id == focus }) else { return nil }
            let start = entries[min(ai, fi)].range.location
            return NSRange(location: start, length: NSMaxRange(entries[max(ai, fi)].range) - start)
        }
    }

    /// A committed native edit is reduced as one grapheme-safe replacement.
    /// This also covers dictation, autocorrection, and composition commit,
    /// without ever serializing provisional marked text.
    func replacement(to newText: String) -> (range: NSRange, text: String)? {
        guard newText != text else { return nil }
        let before = Array(text), after = Array(newText)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        let location = String(before.prefix(prefix)).utf16.count
        let removed = String(before[prefix..<(before.count - suffix)]).utf16.count
        return (NSRange(location: location, length: removed), String(after[prefix..<(after.count - suffix)]))
    }
}
