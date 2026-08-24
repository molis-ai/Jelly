import AppKit
import Foundation
import WorkspaceDomain

extension NSAttributedString.Key {
    static let jellyBlockID = NSAttributedString.Key("com.adeptify.jelly.block-id")
    static let jellyBlockKind = NSAttributedString.Key("com.adeptify.jelly.block-kind")
    static let jellyDivider = NSAttributedString.Key("com.adeptify.jelly.divider")
    static let jellyStructuralSeparator = NSAttributedString.Key("com.adeptify.jelly.structural-separator")
    static let jellyInlineCode = NSAttributedString.Key("com.adeptify.jelly.inline-code")
}

enum BlockTextStyle {
    static let lineFragmentPadding: CGFloat = 5

    static func textColumnOffset(for kind: BlockKind, indentLevel: Int = 0) -> CGFloat {
        paragraphStyle(for: kind, indentLevel: indentLevel).firstLineHeadIndent
            + lineFragmentPadding
    }

    static func attributedString(
        for block: DocumentBlock,
        appearance: CalendarSemanticAppearance?,
        completionDescriptionWidth: CGFloat = NoteEditorLayout.maximumContentWidth - 32
    ) -> NSAttributedString {
        if block.kind == .divider {
            return NSAttributedString(string: "")
        }

        let text = block.inlineContent.spans.map(\.text).joined()
        let attributed = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return attributed }

        let baseFont = baseFont(for: block.kind)
        attributed.addAttributes(
            blockAttributes(for: block, appearance: appearance),
            range: fullRange
        )
        applyTrailingCompletionReserve(
            to: attributed,
            block: block,
            completionDescriptionWidth: completionDescriptionWidth
        )
        var cursor = 0
        for span in block.inlineContent.spans {
            let length = (span.text as NSString).length
            if length > 0 {
                let range = NSRange(location: cursor, length: length)
                attributed.addAttribute(
                    .font,
                    value: styledFont(base: baseFont, marks: span.marks),
                    range: range
                )
                if span.marks.contains(.code) {
                    attributed.addAttribute(.jellyInlineCode, value: true, range: range)
                    attributed.addAttribute(
                        .backgroundColor,
                        value: inlineCodeBackground(appearance: appearance),
                        range: range
                    )
                }
                if let link = span.linkURL, BlockURLValidator.isValid(link) {
                    attributed.addAttributes([
                        .link: link,
                        .foregroundColor: linkColor(appearance: appearance),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ], range: range)
                }
            }
            cursor += length
        }
        return attributed
    }

    static func separator(appearance: CalendarSemanticAppearance?) -> NSAttributedString {
        NSAttributedString(
            string: "\n",
            attributes: [
                .font: baseFont(for: .paragraph),
                .foregroundColor: primaryColor(appearance: appearance),
                .jellyStructuralSeparator: true
            ]
        )
    }

    static func baseFont(for kind: BlockKind) -> NSFont {
        switch kind {
        case .heading1: .systemFont(ofSize: 26, weight: .bold)
        case .heading2: .systemFont(ofSize: 22, weight: .semibold)
        case .heading3: .systemFont(ofSize: 18, weight: .semibold)
        case .code: .monospacedSystemFont(ofSize: 15, weight: .regular)
        case .quote:
            NSFontManager.shared.convert(
                .systemFont(ofSize: NoteEditorLayout.bodyPointSize),
                toHaveTrait: .italicFontMask
            )
        case .paragraph, .bullet, .ordered, .task, .divider, .link:
            .systemFont(ofSize: NoteEditorLayout.bodyPointSize)
        }
    }

    static func baseColor(
        for kind: BlockKind,
        appearance: CalendarSemanticAppearance?
    ) -> NSColor {
        switch kind {
        case .quote:
            appearance.map { color(hex: $0.secondaryTextHex) } ?? .secondaryLabelColor
        case .link:
            linkColor(appearance: appearance)
        case .paragraph, .heading1, .heading2, .heading3, .bullet, .ordered, .task, .code, .divider:
            primaryColor(appearance: appearance)
        }
    }

    static func paragraphStyle(for kind: BlockKind, indentLevel: Int = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.45
        switch kind {
        case .bullet, .ordered, .task:
            style.paragraphSpacing = 0
        case .divider:
            style.paragraphSpacing = 8
        case .paragraph, .heading1, .heading2, .heading3, .quote, .code, .link:
            style.paragraphSpacing = 5
        }
        if [.bullet, .ordered, .task, .quote].contains(kind) {
            let structuralIndent = CGFloat(max(0, indentLevel) * 20)
            style.firstLineHeadIndent = 22 + structuralIndent
            style.headIndent = 22 + structuralIndent
        }
        return style
    }

    static func styledFont(base: NSFont, marks: Set<InlineMark>) -> NSFont {
        var font = marks.contains(.code)
            ? NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
            : base
        if marks.contains(.bold) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if marks.contains(.italic) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    static func secondaryTextColor(appearance: CalendarSemanticAppearance?) -> NSColor {
        appearance.map { color(hex: $0.secondaryTextHex) } ?? .secondaryLabelColor
    }

    static func paragraphStyle(
        for block: DocumentBlock,
        completionDescriptionWidth: CGFloat
    ) -> NSParagraphStyle {
        let style = paragraphStyle(
            for: block.kind,
            indentLevel: block.indentLevel
        ).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        if let extra = TaskCompletionDescriptionMetrics.reservedParagraphSpacing(
            for: block,
            width: completionDescriptionWidth
        ) {
            style.paragraphSpacing += extra
        }
        return style
    }

    static func paragraphRange(in string: NSString, atUTF16Offset location: Int) -> NSRange? {
        guard string.length > 0 else { return nil }
        let clamped = min(max(0, location), string.length - 1)
        var start = 0
        var end = 0
        var contentsEnd = 0
        string.getParagraphStart(
            &start,
            end: &end,
            contentsEnd: &contentsEnd,
            for: NSRange(location: clamped, length: 0)
        )
        let length = end - start
        guard length > 0 else { return nil }
        return NSRange(location: start, length: length)
    }

    private static func applyTrailingCompletionReserve(
        to attributed: NSMutableAttributedString,
        block: DocumentBlock,
        completionDescriptionWidth: CGFloat
    ) {
        guard TaskCompletionDescriptionMetrics.reservedParagraphSpacing(
            for: block,
            width: completionDescriptionWidth
        ) != nil else { return }
        guard let range = paragraphRange(
            in: attributed.string as NSString,
            atUTF16Offset: attributed.length - 1
        ) else { return }
        attributed.addAttribute(
            .paragraphStyle,
            value: paragraphStyle(
                for: block,
                completionDescriptionWidth: completionDescriptionWidth
            ),
            range: range
        )
    }

    private static func blockAttributes(
        for block: DocumentBlock,
        appearance: CalendarSemanticAppearance?
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont(for: block.kind),
            .foregroundColor: baseColor(for: block.kind, appearance: appearance),
            .jellyBlockID: block.id.rawValue.uuidString,
            .jellyBlockKind: block.kind.rawValue
        ]
        attributes[.paragraphStyle] = paragraphStyle(
            for: block.kind,
            indentLevel: block.indentLevel
        )
        if block.kind == .code {
            attributes[.backgroundColor] = codeBackground(appearance: appearance)
        }
        if block.kind == .link {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if block.taskState?.completedAt != nil {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            if let color = attributes[.foregroundColor] as? NSColor {
                attributes[.foregroundColor] = color.withAlphaComponent(
                    TaskCompletionDescriptionMetrics.completedOpacity
                )
            }
        }
        return attributes
    }

    private static func primaryColor(appearance: CalendarSemanticAppearance?) -> NSColor {
        appearance.map { color(hex: $0.primaryTextHex) } ?? .labelColor
    }

    private static func linkColor(appearance: CalendarSemanticAppearance?) -> NSColor {
        appearance.map { color(hex: $0.controlAccentHex) } ?? .linkColor
    }

    private static func codeBackground(appearance: CalendarSemanticAppearance?) -> NSColor {
        appearance.map { color(hex: $0.elevatedSurfaceHex).withAlphaComponent(0.7) }
            ?? NSColor.textBackgroundColor.withAlphaComponent(0.7)
    }

    private static func inlineCodeBackground(appearance: CalendarSemanticAppearance?) -> NSColor {
        appearance.map { color(hex: $0.separatorHex).withAlphaComponent(0.45) }
            ?? .quaternaryLabelColor
    }

    private static func color(hex: String) -> NSColor {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
