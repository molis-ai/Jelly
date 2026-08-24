import AppKit
import Foundation

// MARK: - Commands

enum MarkdownNotesCommand: Equatable, Sendable {
    case heading
    case bold
    case italic
    case checklist
    case unorderedList
    case orderedList
}

// MARK: - Block kinds

enum NotesBlockKind: String, Equatable, Sendable {
    case paragraph
    case heading
    case bullet
    case ordered
    case checklist
}

extension NSAttributedString.Key {
    static let notesBlock = NSAttributedString.Key("com.jelly.notes.block")
    static let notesChecked = NSAttributedString.Key("com.jelly.notes.checked")
}

// MARK: - Metrics

struct NotesRichTextMetrics: Equatable {
    let bodySize: CGFloat
    let headingSize: CGFloat
    let textColor: NSColor
    let secondaryColor: NSColor
    let accentColor: NSColor

    static func make(theme: CalendarSemanticAppearance, appearance: CalendarAppearance) -> NotesRichTextMetrics {
        NotesRichTextMetrics(
            bodySize: 12.5,
            headingSize: 15.5,
            textColor: NSColor(theme.primaryText),
            secondaryColor: NSColor(theme.secondaryText),
            accentColor: NSColor(theme.controlAccent)
        )
    }
}

// MARK: - Codec

/// WYSIWYG rich text ↔ Markdown storage.
/// Lists use visible display prefixes in the editor:
///   bullet `• `, ordered `1. `, checklist `☐ `/`☑ `
/// Markdown storage still uses `- `, `1. `, `- [ ]`.
enum MarkdownRichTextCodec {
    private static let bulletPrefix = "• "
    private static let checkOpen = "☐ "
    private static let checkDone = "☑ "

    // MARK: Markdown → rich

    static func attributedString(
        from markdown: String,
        metrics: NotesRichTextMetrics
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = splitLines(markdown)
        guard !lines.isEmpty else { return defaultEmpty(metrics: metrics) }

        var orderedCounter = 0
        for (index, rawLine) in lines.enumerated() {
            let parsed = parseLine(rawLine)
            if parsed.kind == .ordered {
                orderedCounter += 1
            } else {
                orderedCounter = 0
            }

            let lineAttr = attributes(for: parsed.kind, checked: parsed.checked, metrics: metrics)
            let display = displayContent(
                kind: parsed.kind,
                checked: parsed.checked,
                body: parsed.content,
                orderedIndex: orderedCounter
            )
            var content = NSMutableAttributedString(string: display, attributes: lineAttr)
            // Inline markers only apply to body after the display prefix.
            applyInlineMarkdownToBody(&content, kind: parsed.kind, metrics: metrics, base: lineAttr)
            result.append(content)
            if index < lines.count - 1 || markdown.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n", attributes: lineAttr))
            }
        }
        return result.length == 0 ? defaultEmpty(metrics: metrics) : result
    }

    // MARK: Rich → Markdown

    static func markdown(from attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        let ns = attributed.string as NSString
        var output: [String] = []
        var location = 0
        var orderedIndex = 0

        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(lineRange) }

            var bodyRange = lineRange
            if bodyRange.length > 0 {
                let last = ns.character(at: NSMaxRange(bodyRange) - 1)
                if last == 10 || last == 13 { bodyRange.length -= 1 }
            }

            if bodyRange.length == 0 {
                output.append("")
                orderedIndex = 0
                continue
            }

            // Infer block from attributes first; fall back to display prefix.
            var block = blockKind(in: attributed, at: bodyRange.location)
            let lineText = ns.substring(with: bodyRange)
            if block == .paragraph {
                block = inferKindFromDisplayPrefix(lineText)
            }

            if block != .ordered { orderedIndex = 0 }

            let stripped = stripDisplayPrefix(lineText, kind: block)
            let inlineRange = NSRange(
                location: bodyRange.location + (bodyRange.length - (stripped as NSString).length),
                length: (stripped as NSString).length
            )
            // Serialize inline formatting from the body portion only.
            let inline: String
            if inlineRange.length > 0, inlineRange.location + inlineRange.length <= attributed.length {
                inline = serializeInline(attributed, range: inlineRange)
            } else {
                inline = stripped
            }

            switch block {
            case .paragraph:
                output.append(inline)
            case .heading:
                output.append("## \(inline)")
            case .bullet:
                output.append("- \(inline)")
            case .ordered:
                orderedIndex += 1
                output.append("\(orderedIndex). \(inline)")
            case .checklist:
                let checked = isChecked(in: attributed, at: bodyRange.location)
                    || lineText.hasPrefix("☑")
                output.append(checked ? "- [x] \(inline)" : "- [ ] \(inline)")
            }
        }

        var md = output.joined(separator: "\n")
        if attributed.string.hasSuffix("\n"), !md.hasSuffix("\n") {
            md += "\n"
        }
        return md
    }

    // MARK: Toolbar

    static func apply(
        _ command: MarkdownNotesCommand,
        to attributed: NSAttributedString,
        selectedRange: NSRange,
        metrics: NotesRichTextMetrics
    ) -> (NSAttributedString, NSRange) {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let length = mutable.length
        let selection = clamp(selectedRange, length: length)

        switch command {
        case .bold:
            toggleTrait(.boldFontMask, in: mutable, range: effectiveInlineRange(selection, length: length), metrics: metrics)
        case .italic:
            toggleTrait(.italicFontMask, in: mutable, range: effectiveInlineRange(selection, length: length), metrics: metrics)
        case .heading:
            toggleBlock(.heading, in: mutable, selection: selection, metrics: metrics)
        case .checklist:
            toggleBlock(.checklist, in: mutable, selection: selection, metrics: metrics)
        case .unorderedList:
            toggleBlock(.bullet, in: mutable, selection: selection, metrics: metrics)
        case .orderedList:
            toggleBlock(.ordered, in: mutable, selection: selection, metrics: metrics)
        }

        // Keep ordered numbers contiguous after any list mutation.
        if command == .orderedList || command == .unorderedList || command == .checklist || command == .heading {
            renumberOrderedLists(in: mutable, metrics: metrics)
        }

        switch command {
        case .checklist, .unorderedList, .orderedList:
            return (mutable, selectionAfterListMarkerChange(
                before: attributed,
                after: mutable,
                selection: selection
            ))
        case .heading, .bold, .italic:
            let newLen = mutable.length
            let loc = min(selection.location, newLen)
            let len = min(selection.length, max(0, newLen - loc))
            return (mutable, NSRange(location: loc, length: len))
        }
    }

    /// After inserting or removing a list marker, the caret must sit at the
    /// body — to the right of `☐ ` / `• ` / `1. ` — not on the marker itself.
    private static func selectionAfterListMarkerChange(
        before: NSAttributedString,
        after: NSAttributedString,
        selection: NSRange
    ) -> NSRange {
        let newLen = after.length
        if newLen == 0 {
            return NSRange(location: 0, length: 0)
        }
        if before.length == 0 {
            return NSRange(location: newLen, length: 0)
        }

        let oldNS = before.string as NSString
        let oldCaret = min(max(0, selection.location), oldNS.length)
        let oldLine = oldNS.lineRange(
            for: NSRange(location: min(oldCaret, max(0, oldNS.length - 1)), length: 0)
        )
        var oldBody = oldLine
        if oldBody.length > 0 {
            let last = oldNS.character(at: NSMaxRange(oldBody) - 1)
            if last == 10 || last == 13 { oldBody.length -= 1 }
        }
        let oldLineText = oldBody.length > 0 ? oldNS.substring(with: oldBody) : ""
        let oldKind = oldBody.length > 0
            ? blockKind(in: before, at: oldBody.location)
            : .paragraph
        let oldPrefix = displayPrefixLength(kind: oldKind, line: oldLineText)

        let newNS = after.string as NSString
        let newLineLoc = min(oldLine.location, newLen - 1)
        let newLine = newNS.lineRange(for: NSRange(location: newLineLoc, length: 0))
        var newBody = newLine
        if newBody.length > 0 {
            let last = newNS.character(at: NSMaxRange(newBody) - 1)
            if last == 10 || last == 13 { newBody.length -= 1 }
        }
        let newLineText = newBody.length > 0 ? newNS.substring(with: newBody) : ""
        let newKind = newBody.length > 0
            ? blockKind(in: after, at: newBody.location)
            : .paragraph
        let newPrefix = displayPrefixLength(kind: newKind, line: newLineText)

        let bodyStart = newLine.location + newPrefix
        let bodyEnd = NSMaxRange(newBody)
        if selection.length == 0 {
            let mapped = selection.location + (newPrefix - oldPrefix)
            let loc = min(max(mapped, bodyStart), max(bodyStart, bodyEnd))
            return NSRange(location: min(loc, newLen), length: 0)
        }

        let loc = min(max(selection.location + (newPrefix - oldPrefix), bodyStart), newLen)
        let end = min(selection.location + selection.length + (newPrefix - oldPrefix), max(loc, bodyEnd))
        return NSRange(location: loc, length: max(0, end - loc))
    }

    /// Toggle ☐ ↔ ☑. `characterIndex` may be anywhere on the checklist line
    /// (clicks near the glyph or with slightly off hit-testing still work).
    static func toggleChecklistChecked(
        in attributed: NSAttributedString,
        at characterIndex: Int,
        metrics: NotesRichTextMetrics
    ) -> NSAttributedString? {
        guard attributed.length > 0 else { return nil }
        let ns = attributed.string as NSString
        let idx = min(max(0, characterIndex), ns.length - 1)
        let lineRange = ns.lineRange(for: NSRange(location: idx, length: 0))
        var bodyRange = lineRange
        if bodyRange.length > 0 {
            let last = ns.character(at: NSMaxRange(bodyRange) - 1)
            if last == 10 || last == 13 { bodyRange.length -= 1 }
        }
        guard bodyRange.length > 0 else { return nil }

        let lineText = ns.substring(with: bodyRange)
        let kind = blockKind(in: attributed, at: bodyRange.location)
        let looksChecklist = kind == .checklist
            || lineText.hasPrefix("☐")
            || lineText.hasPrefix("☑")
        guard looksChecklist else { return nil }

        // Allow click on glyph OR first few characters of the line (easier hit target).
        let hitEnd = min(bodyRange.location + 3, NSMaxRange(bodyRange))
        guard characterIndex < hitEnd || kind == .checklist else { return nil }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let currentlyChecked = isChecked(in: attributed, at: bodyRange.location)
            || lineText.hasPrefix("☑")
        let nextChecked = !currentlyChecked
        let body = stripAnyListPrefix(lineText)
        let display = (nextChecked ? checkDone : checkOpen) + body
        let attrs = attributes(for: .checklist, checked: nextChecked, metrics: metrics)
        let replacement = NSMutableAttributedString(string: display, attributes: attrs)
        // Preserve fonts on body.
        let oldBodyStart = (lineText as NSString).length - (body as NSString).length
        if oldBodyStart >= 0, (body as NSString).length > 0 {
            copyInlineFonts(
                from: attributed,
                sourceRange: NSRange(
                    location: bodyRange.location + oldBodyStart,
                    length: (body as NSString).length
                ),
                to: replacement,
                destStart: (checkOpen as NSString).length,
                metrics: metrics
            )
        }
        mutable.replaceCharacters(in: bodyRange, with: replacement)
        return mutable
    }

    // MARK: - Display helpers

    private static func displayContent(
        kind: NotesBlockKind,
        checked: Bool,
        body: String,
        orderedIndex: Int
    ) -> String {
        switch kind {
        case .paragraph, .heading:
            return body
        case .bullet:
            return bulletPrefix + body
        case .ordered:
            return "\(max(1, orderedIndex)). " + body
        case .checklist:
            return (checked ? checkDone : checkOpen) + body
        }
    }

    private static func stripDisplayPrefix(_ line: String, kind: NotesBlockKind) -> String {
        // Unified stripping — kind only used for intent documentation.
        _ = kind
        return stripAnyListPrefix(line)
    }

    private static func inferKindFromDisplayPrefix(_ line: String) -> NotesBlockKind {
        if line.hasPrefix(checkOpen) || line.hasPrefix(checkDone) || line.hasPrefix("☐") || line.hasPrefix("☑") {
            return .checklist
        }
        if line.hasPrefix(bulletPrefix) || line.hasPrefix("•") { return .bullet }
        if stripPrefix(line, pattern: #"^\d+\.\s+"#) != nil { return .ordered }
        if stripPrefix(line, pattern: #"^#{1,3}\s+"#) != nil { return .heading }
        return .paragraph
    }

    // MARK: - Parse markdown line

    private struct ParsedLine {
        var kind: NotesBlockKind
        var checked: Bool
        var content: String
    }

    private static func parseLine(_ raw: String) -> ParsedLine {
        if let rest = stripPrefix(raw, pattern: #"^#{1,3}\s+"#) {
            return ParsedLine(kind: .heading, checked: false, content: rest)
        }
        if let rest = stripPrefix(raw, pattern: #"^- \[[xX]\]\s*"#) {
            return ParsedLine(kind: .checklist, checked: true, content: rest)
        }
        if let rest = stripPrefix(raw, pattern: #"^- \[[ ]\]\s*"#) {
            return ParsedLine(kind: .checklist, checked: false, content: rest)
        }
        if let rest = stripPrefix(raw, pattern: #"^[-*]\s+"#) {
            return ParsedLine(kind: .bullet, checked: false, content: rest)
        }
        if let rest = stripPrefix(raw, pattern: #"^\d+\.\s+"#) {
            return ParsedLine(kind: .ordered, checked: false, content: rest)
        }
        return ParsedLine(kind: .paragraph, checked: false, content: raw)
    }

    private static func stripPrefix(_ line: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: line, options: [], range: full),
              match.range.location == 0
        else { return nil }
        return ns.substring(from: match.range.length)
    }

    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [""] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n"), let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines.isEmpty ? [""] : lines
    }

    // MARK: - Attributes

    private static func defaultEmpty(metrics: NotesRichTextMetrics) -> NSAttributedString {
        NSAttributedString(string: "", attributes: attributes(for: .paragraph, checked: false, metrics: metrics))
    }

    private static func attributes(
        for kind: NotesBlockKind,
        checked: Bool,
        metrics: NotesRichTextMetrics
    ) -> [NSAttributedString.Key: Any] {
        let size = kind == .heading ? metrics.headingSize : metrics.bodySize
        let weight: NSFont.Weight = kind == .heading ? .semibold : .regular
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: metrics.textColor,
            .notesBlock: kind.rawValue
        ]
        if kind == .checklist {
            attrs[.notesChecked] = checked
        }
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = kind == .heading ? 4 : 2
        // No NSTextList — markers are real characters (reliable in NSTextView).
        if kind == .bullet || kind == .ordered || kind == .checklist {
            para.headIndent = 4
        }
        attrs[.paragraphStyle] = para
        return attrs
    }

    // MARK: - Inline markdown in body only

    private static func applyInlineMarkdownToBody(
        _ content: inout NSMutableAttributedString,
        kind: NotesBlockKind,
        metrics: NotesRichTextMetrics,
        base: [NSAttributedString.Key: Any]
    ) {
        let prefixLen = displayPrefixLength(kind: kind, line: content.string)
        let full = content.string as NSString
        guard full.length > prefixLen else { return }
        let bodyRange = NSRange(location: prefixLen, length: full.length - prefixLen)
        let bodyString = full.substring(with: bodyRange)
        var bodyAttr = NSMutableAttributedString(string: bodyString, attributes: base)
        replaceInline(in: &bodyAttr, pattern: #"\*\*(.+?)\*\*"#, metrics: metrics, bold: true, italic: false, base: base)
        replaceInline(in: &bodyAttr, pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, metrics: metrics, bold: false, italic: true, base: base)
        content.replaceCharacters(in: bodyRange, with: bodyAttr)
    }

    private static func displayPrefixLength(kind: NotesBlockKind, line: String) -> Int {
        switch kind {
        case .bullet:
            if line.hasPrefix(bulletPrefix) { return (bulletPrefix as NSString).length }
            return 0
        case .ordered:
            if let rest = stripPrefix(line, pattern: #"^\d+\.\s+"#) {
                return (line as NSString).length - (rest as NSString).length
            }
            return 0
        case .checklist:
            if line.hasPrefix(checkOpen) || line.hasPrefix(checkDone) {
                return (checkOpen as NSString).length
            }
            return 0
        case .paragraph, .heading:
            return 0
        }
    }

    private static func replaceInline(
        in content: inout NSMutableAttributedString,
        pattern: String,
        metrics: NotesRichTextMetrics,
        bold: Bool,
        italic: Bool,
        base: [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let full = NSRange(location: 0, length: content.length)
        let matches = regex.matches(in: content.string, options: [], range: full).reversed()
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let whole = match.range(at: 0)
            let inner = match.range(at: 1)
            guard whole.location != NSNotFound, inner.location != NSNotFound else { continue }
            let innerText = (content.string as NSString).substring(with: inner)
            var attrs = base
            let baseFont = (base[.font] as? NSFont) ?? NSFont.systemFont(ofSize: metrics.bodySize)
            var font = baseFont
            if bold { font = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .bold) }
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            attrs[.font] = font
            content.replaceCharacters(in: whole, with: NSAttributedString(string: innerText, attributes: attrs))
        }
    }

    private static func serializeInline(_ attributed: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        attributed.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            let chunk = (attributed.string as NSString).substring(with: subRange)
            guard !chunk.isEmpty else { return }
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let isBold = traits.contains(.boldFontMask)
            let isItalic = traits.contains(.italicFontMask)
            if isBold && isItalic {
                result += "***\(chunk)***"
            } else if isBold {
                result += "**\(chunk)**"
            } else if isItalic {
                result += "*\(chunk)*"
            } else {
                result += chunk
            }
        }
        return result
    }

    private static func blockKind(in attributed: NSAttributedString, at location: Int) -> NotesBlockKind {
        guard location < attributed.length else { return .paragraph }
        let raw = attributed.attribute(.notesBlock, at: location, effectiveRange: nil) as? String
        return NotesBlockKind(rawValue: raw ?? "") ?? .paragraph
    }

    private static func isChecked(in attributed: NSAttributedString, at location: Int) -> Bool {
        guard location < attributed.length else { return false }
        return (attributed.attribute(.notesChecked, at: location, effectiveRange: nil) as? Bool) ?? false
    }

    // MARK: - Traits

    private static func effectiveInlineRange(_ selection: NSRange, length: Int) -> NSRange {
        selection.length > 0 ? clamp(selection, length: length) : selection
    }

    private static func toggleTrait(
        _ trait: NSFontTraitMask,
        in mutable: NSMutableAttributedString,
        range: NSRange,
        metrics: NotesRichTextMetrics
    ) {
        guard range.length > 0, range.location + range.length <= mutable.length else { return }
        var shouldEnable = false
        mutable.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: metrics.bodySize)
            if !NSFontManager.shared.traits(of: font).contains(trait) {
                shouldEnable = true
                stop.pointee = true
            }
        }
        mutable.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: metrics.bodySize)
            let next = shouldEnable
                ? NSFontManager.shared.convert(font, toHaveTrait: trait)
                : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            mutable.addAttribute(.font, value: next, range: subRange)
        }
    }

    // MARK: - Block toggle (standard list-toolbar semantics)

    private static func toggleBlock(
        _ kind: NotesBlockKind,
        in mutable: NSMutableAttributedString,
        selection: NSRange,
        metrics: NotesRichTextMetrics
    ) {
        // Empty document: seed a list/heading line so the user immediately sees the marker.
        if mutable.length == 0 {
            let display: String
            switch kind {
            case .bullet: display = bulletPrefix
            case .ordered: display = "1. "
            case .checklist: display = checkOpen
            case .heading, .paragraph: display = ""
            }
            let attrs = attributes(for: kind, checked: false, metrics: metrics)
            mutable.append(NSAttributedString(string: display, attributes: attrs))
            return
        }

        let ns = mutable.string as NSString
        let length = mutable.length

        // Empty selection → current line only (avoids checklist lines "kicking" each other).
        // Non-empty selection → all lines touched by the selection.
        let start: Int
        let paraEnd: Int
        if selection.length == 0 {
            let caret = min(max(0, selection.location), max(0, length - 1))
            let line = ns.lineRange(for: NSRange(location: caret, length: 0))
            start = line.location
            paraEnd = NSMaxRange(line)
        } else {
            start = ns.lineRange(for: NSRange(location: min(selection.location, length - 1), length: 0)).location
            let endSel = min(selection.location + selection.length, length)
            let endLine = ns.lineRange(for: NSRange(location: min(max(endSel - 1, 0), length - 1), length: 0))
            paraEnd = NSMaxRange(endLine)
        }

        // Collect line body ranges first (mutating invalidates NSString line walks).
        var lineBodies: [NSRange] = []
        var loc = start
        while loc < paraEnd && loc < mutable.length {
            let lr = (mutable.string as NSString).lineRange(for: NSRange(location: loc, length: 0))
            var br = lr
            if br.length > 0 {
                let last = (mutable.string as NSString).character(at: NSMaxRange(br) - 1)
                if last == 10 || last == 13 { br.length -= 1 }
            }
            lineBodies.append(br)
            loc = NSMaxRange(lr)
            if lr.length == 0 { break }
        }
        guard !lineBodies.isEmpty else { return }

        // Standard toolbar: if EVERY target line is already `kind`, turn all OFF;
        // otherwise turn all ON to `kind` (no per-line flip-flop).
        let allAlreadyKind = lineBodies.allSatisfy { br in
            guard br.length > 0, br.location < mutable.length else { return false }
            return blockKind(in: mutable, at: br.location) == kind
        }
        let nextKind: NotesBlockKind = allAlreadyKind ? .paragraph : kind

        for br in lineBodies.reversed() {
            setLineBlock(nextKind, bodyRange: br, in: mutable, metrics: metrics)
        }
    }

    /// Force a line to `nextKind` (not a per-line toggle).
    private static func setLineBlock(
        _ nextKind: NotesBlockKind,
        bodyRange: NSRange,
        in mutable: NSMutableAttributedString,
        metrics: NotesRichTextMetrics
    ) {
        guard bodyRange.location <= mutable.length else { return }
        let ns = mutable.string as NSString
        let safeLength = min(bodyRange.length, max(0, mutable.length - bodyRange.location))
        let br = NSRange(location: bodyRange.location, length: safeLength)
        let lineText = br.length > 0 ? ns.substring(with: br) : ""

        let current: NotesBlockKind = br.length > 0
            ? blockKind(in: mutable, at: br.location)
            : .paragraph
        let wasChecked = br.length > 0 && (
            isChecked(in: mutable, at: br.location) || lineText.hasPrefix("☑")
        )

        let body = stripAnyListPrefix(lineText)
        let checked = (nextKind == .checklist) && wasChecked && current == .checklist
        let display: String
        switch nextKind {
        case .paragraph, .heading:
            display = body
        case .bullet:
            display = bulletPrefix + body
        case .ordered:
            display = "1. " + body // renumber pass fixes index
        case .checklist:
            display = (checked ? checkDone : checkOpen) + body
        }

        let attrs = attributes(for: nextKind, checked: checked, metrics: metrics)
        let replacement = NSMutableAttributedString(string: display, attributes: attrs)
        if br.length > 0 {
            let oldBody = stripAnyListPrefix(lineText)
            let oldBodyStartInLine = (lineText as NSString).length - (oldBody as NSString).length
            if oldBodyStartInLine >= 0, (oldBody as NSString).length > 0 {
                let oldBodyRange = NSRange(
                    location: br.location + oldBodyStartInLine,
                    length: (oldBody as NSString).length
                )
                let newBodyStart = displayPrefixLength(kind: nextKind, line: display)
                copyInlineFonts(
                    from: mutable,
                    sourceRange: oldBodyRange,
                    to: replacement,
                    destStart: newBodyStart,
                    metrics: metrics
                )
            }
            mutable.replaceCharacters(in: br, with: replacement)
        } else {
            mutable.insert(replacement, at: br.location)
        }
    }

    private static func stripAnyListPrefix(_ line: String) -> String {
        let ns = line as NSString
        if ns.hasPrefix("☐ ") || ns.hasPrefix("☑ ") {
            return ns.substring(from: 2)
        }
        if ns.hasPrefix("☐") || ns.hasPrefix("☑") {
            return ns.substring(from: 1).trimmingCharacters(in: .whitespaces)
        }
        if ns.hasPrefix(bulletPrefix) {
            return ns.substring(from: (bulletPrefix as NSString).length)
        }
        if ns.hasPrefix("•") {
            return ns.substring(from: 1).trimmingCharacters(in: .whitespaces)
        }
        if let rest = stripPrefix(line, pattern: #"^\d+\.\s+"#) { return rest }
        // Markdown checklist before plain dash.
        if let rest = stripPrefix(line, pattern: #"^- \[[xX ]\]\s*"#) { return rest }
        if let rest = stripPrefix(line, pattern: #"^[-*]\s+"#) { return rest }
        if let rest = stripPrefix(line, pattern: #"^#{1,3}\s+"#) { return rest }
        return line
    }

    private static func copyInlineFonts(
        from source: NSAttributedString,
        sourceRange: NSRange,
        to dest: NSMutableAttributedString,
        destStart: Int,
        metrics: NotesRichTextMetrics
    ) {
        guard sourceRange.length > 0,
              sourceRange.location + sourceRange.length <= source.length
        else { return }
        source.enumerateAttribute(.font, in: sourceRange, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let offset = range.location - sourceRange.location
            let destRange = NSRange(location: destStart + offset, length: range.length)
            guard destRange.location + destRange.length <= dest.length else { return }
            dest.addAttribute(.font, value: font, range: destRange)
        }
    }

    /// Rewrite `1. 2. 3.` for contiguous ordered lines.
    private static func renumberOrderedLists(
        in mutable: NSMutableAttributedString,
        metrics: NotesRichTextMetrics
    ) {
        let ns = mutable.string as NSString
        var location = 0
        var index = 0
        var replacements: [(NSRange, String, NotesBlockKind)] = []

        while location < ns.length {
            let lr = ns.lineRange(for: NSRange(location: location, length: 0))
            var br = lr
            if br.length > 0 {
                let last = ns.character(at: NSMaxRange(br) - 1)
                if last == 10 || last == 13 { br.length -= 1 }
            }
            defer { location = NSMaxRange(lr) }

            guard br.length > 0 else {
                index = 0
                continue
            }
            let lineText = ns.substring(with: br)
            let kind = blockKind(in: mutable, at: br.location) != .paragraph
                ? blockKind(in: mutable, at: br.location)
                : inferKindFromDisplayPrefix(lineText)

            if kind == .ordered {
                index += 1
                let body = stripAnyListPrefix(lineText)
                let display = "\(index). \(body)"
                if display != lineText {
                    replacements.append((br, display, .ordered))
                }
            } else {
                index = 0
            }
        }

        for (br, display, kind) in replacements.reversed() {
            let attrs = attributes(for: kind, checked: false, metrics: metrics)
            // Keep existing fonts on body if possible.
            let oldBody = stripAnyListPrefix((mutable.string as NSString).substring(with: br))
            let replacement = NSMutableAttributedString(string: display, attributes: attrs)
            let newBodyStart = displayPrefixLength(kind: kind, line: display)
            let oldBodyStart = br.length - (oldBody as NSString).length
            if oldBodyStart >= 0 {
                copyInlineFonts(
                    from: mutable,
                    sourceRange: NSRange(location: br.location + oldBodyStart, length: (oldBody as NSString).length),
                    to: replacement,
                    destStart: newBodyStart,
                    metrics: metrics
                )
            }
            mutable.replaceCharacters(in: br, with: replacement)
        }
    }

    private static func clamp(_ range: NSRange, length: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let loc = min(max(0, range.location), length)
        let len = min(max(0, range.length), length - loc)
        return NSRange(location: loc, length: len)
    }
}
