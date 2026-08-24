import AppKit
import Foundation
import Testing
@testable import CalendarApp

@Suite("MarkdownRichTextCodecTests")
struct MarkdownRichTextCodecTests {
    private var metrics: NotesRichTextMetrics {
        NotesRichTextMetrics(
            bodySize: 12.5,
            headingSize: 15.5,
            textColor: .labelColor,
            secondaryColor: .secondaryLabelColor,
            accentColor: .systemOrange
        )
    }

    // MARK: Load (Markdown → WYSIWYG string)

    @Test func loadBulletShowsDotNotMarkdownDash() {
        let rich = MarkdownRichTextCodec.attributedString(
            from: "- 可能\n- 你\n- 重新开车",
            metrics: metrics
        )
        let plain = rich.string
        #expect(plain.contains("• 可能"))
        #expect(plain.contains("• 你"))
        #expect(plain.contains("• 重新开车"))
        // Must NOT look like raw markdown the user complained about.
        #expect(!plain.contains("- 可能"))
        #expect(!plain.hasPrefix("- "))
        #expect(!plain.contains("\n- "))
    }

    @Test func loadOrderedShowsNumbers() {
        let rich = MarkdownRichTextCodec.attributedString(
            from: "1. 一\n2. 二\n3. 三",
            metrics: metrics
        )
        let plain = rich.string
        #expect(plain.contains("1. 一"))
        #expect(plain.contains("2. 二"))
        #expect(plain.contains("3. 三"))
    }

    @Test func loadChecklistShowsGlyphsNotBrackets() {
        let rich = MarkdownRichTextCodec.attributedString(
            from: "- [ ] 未完成\n- [x] 已完成",
            metrics: metrics
        )
        let plain = rich.string
        #expect(plain.contains("☐ 未完成"))
        #expect(plain.contains("☑ 已完成"))
        #expect(!plain.contains("- [ ]"))
        #expect(!plain.contains("- [x]"))
    }

    @Test func loadBoldHasNoAsterisks() {
        let rich = MarkdownRichTextCodec.attributedString(
            from: "这是 **重点**",
            metrics: metrics
        )
        #expect(rich.string == "这是 重点")
        #expect(!rich.string.contains("**"))
    }

    // MARK: Toolbar apply

    @Test func toolbarUnorderedConvertsPlainLinesToDots() {
        let base = MarkdownRichTextCodec.attributedString(
            from: "可能\n你\n重新开车",
            metrics: metrics
        )
        // Select all three lines
        let all = NSRange(location: 0, length: base.length)
        let (listed, _) = MarkdownRichTextCodec.apply(
            .unorderedList,
            to: base,
            selectedRange: all,
            metrics: metrics
        )
        let plain = listed.string
        #expect(plain.contains("• 可能"), "got=\(plain)")
        #expect(plain.contains("• 你"), "got=\(plain)")
        #expect(plain.contains("• 重新开车"), "got=\(plain)")
        #expect(!plain.contains("\n- "), "must not keep markdown dash; got=\(plain)")
        #expect(!plain.hasPrefix("- "), "got=\(plain)")
    }

    @Test func toolbarUnorderedEmptySelectionOnlyCurrentLine() {
        // Empty selection = current line only (checklist lines must not kick each other).
        let typed = NSMutableAttributedString(
            string: "可能\n你\n重新开车",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .notesBlock: NotesBlockKind.paragraph.rawValue
            ]
        )
        // Caret on first line
        let (listed, _) = MarkdownRichTextCodec.apply(
            .unorderedList,
            to: typed,
            selectedRange: NSRange(location: 0, length: 0),
            metrics: metrics
        )
        let plain = listed.string
        #expect(plain.hasPrefix("• 可能"), "got=\(plain)")
        #expect(plain.contains("\n你\n") || plain.contains("\n你"), "got=\(plain)")
        #expect(!plain.contains("• 你"), "only current line; got=\(plain)")
    }

    @Test func toolbarUnorderedSelectAllConvertsAllLines() {
        let typed = NSMutableAttributedString(
            string: "可能\n你\n重新开车",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .notesBlock: NotesBlockKind.paragraph.rawValue
            ]
        )
        let (listed, _) = MarkdownRichTextCodec.apply(
            .unorderedList,
            to: typed,
            selectedRange: NSRange(location: 0, length: typed.length),
            metrics: metrics
        )
        let plain = listed.string
        #expect(plain.contains("• 可能") && plain.contains("• 你") && plain.contains("• 重新开车"), "got=\(plain)")
    }

    @Test func checklistToolbarDoesNotFlipOtherChecklistLines() {
        let base = MarkdownRichTextCodec.attributedString(
            from: "- [ ] 一\n- [ ] 二\n普通",
            metrics: metrics
        )
        // Caret on "普通" only
        let ns = base.string as NSString
        let plainLoc = ns.range(of: "普通").location
        let (r, _) = MarkdownRichTextCodec.apply(
            .checklist,
            to: base,
            selectedRange: NSRange(location: plainLoc, length: 0),
            metrics: metrics
        )
        // First two stay checklist; third becomes checklist.
        #expect(r.string.contains("☐ 一"), "got=\(r.string)")
        #expect(r.string.contains("☐ 二"), "got=\(r.string)")
        #expect(r.string.contains("☐ 普通"), "got=\(r.string)")
    }

    @Test func checklistToolbarSecondClickOnLineTurnsOffOnlyThatLine() {
        let base = MarkdownRichTextCodec.attributedString(from: "- [ ] 一\n- [ ] 二", metrics: metrics)
        let (off, _) = MarkdownRichTextCodec.apply(
            .checklist,
            to: base,
            selectedRange: NSRange(location: 0, length: 0),
            metrics: metrics
        )
        #expect(off.string.hasPrefix("一"), "got=\(off.string)")
        #expect(off.string.contains("☐ 二"), "got=\(off.string)")
    }

    @Test func checklistTogglePreservesCheckedOnSibling() {
        let base = MarkdownRichTextCodec.attributedString(
            from: "- [x] 已完成\n- [ ] 未完成",
            metrics: metrics
        )
        // Toggle only second line's checkbox
        let ns = base.string as NSString
        let idx = ns.range(of: "☐").location
        let toggled = MarkdownRichTextCodec.toggleChecklistChecked(in: base, at: idx, metrics: metrics)!
        #expect(toggled.string.contains("☑ 已完成"), "got=\(toggled.string)")
        #expect(toggled.string.contains("☑ 未完成"), "got=\(toggled.string)")
        let md = MarkdownRichTextCodec.markdown(from: toggled)
        #expect(md.contains("- [x] 已完成"), "md=\(md)")
        #expect(md.contains("- [x] 未完成"), "md=\(md)")
    }

    @Test func toolbarUnorderedConvertsTypedMarkdownDashes() {
        // User typed "- 可能" as plain text (what the screenshot shows)
        let base = MarkdownRichTextCodec.attributedString(
            from: "可能", // start plain
            metrics: metrics
        )
        // Simulate user having typed dashes: inject as paragraph text
        let typed = NSMutableAttributedString(
            string: "- 可能\n- 你\n- 重新开车",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .notesBlock: NotesBlockKind.paragraph.rawValue
            ]
        )
        let all = NSRange(location: 0, length: typed.length)
        let (listed, _) = MarkdownRichTextCodec.apply(
            .unorderedList,
            to: typed,
            selectedRange: all,
            metrics: metrics
        )
        let plain = listed.string
        #expect(plain.contains("• 可能"), "got=\(plain)")
        #expect(plain.contains("• 你"), "got=\(plain)")
        #expect(plain.contains("• 重新开车"), "got=\(plain)")
        #expect(!plain.contains("- 可能"), "got=\(plain)")
        #expect(!plain.contains("\n- "), "got=\(plain)")
        _ = base
    }

    @Test func toolbarOrderedNumbersLines() {
        let base = MarkdownRichTextCodec.attributedString(
            from: "一\n二\n三",
            metrics: metrics
        )
        let (listed, _) = MarkdownRichTextCodec.apply(
            .orderedList,
            to: base,
            selectedRange: NSRange(location: 0, length: base.length),
            metrics: metrics
        )
        let plain = listed.string
        #expect(plain.contains("1. 一"), "got=\(plain)")
        #expect(plain.contains("2. 二"), "got=\(plain)")
        #expect(plain.contains("3. 三"), "got=\(plain)")
    }

    @Test func toolbarUnorderedOnEmptySeedsBulletLine() {
        let empty = NSAttributedString(string: "")
        let (listed, _) = MarkdownRichTextCodec.apply(
            .unorderedList,
            to: empty,
            selectedRange: NSRange(location: 0, length: 0),
            metrics: metrics
        )
        #expect(listed.string.hasPrefix("•"), "got=\(listed.string)")
    }

    @Test func toolbarListOnEmptyPutsCaretAfterMarker() {
        let empty = NSAttributedString(string: "")
        let cases: [(MarkdownNotesCommand, String)] = [
            (.checklist, "☐ "),
            (.unorderedList, "• "),
            (.orderedList, "1. ")
        ]
        for (command, prefix) in cases {
            let (listed, caret) = MarkdownRichTextCodec.apply(
                command,
                to: empty,
                selectedRange: NSRange(location: 0, length: 0),
                metrics: metrics
            )
            let prefixLen = (prefix as NSString).length
            #expect(listed.string.hasPrefix(prefix), "command=\(command) got=\(listed.string)")
            #expect(caret == NSRange(location: prefixLen, length: 0), "command=\(command) caret=\(caret)")
        }
    }

    @Test func toolbarListOnPlainLinePutsCaretAfterMarkerNotAtLineStart() {
        let plain = MarkdownRichTextCodec.attributedString(from: "创建账号", metrics: metrics)
        let (listed, caret) = MarkdownRichTextCodec.apply(
            .checklist,
            to: plain,
            selectedRange: NSRange(location: 0, length: 0),
            metrics: metrics
        )
        let prefixLen = ("☐ " as NSString).length
        #expect(listed.string.hasPrefix("☐ 创建账号"), "got=\(listed.string)")
        #expect(caret == NSRange(location: prefixLen, length: 0), "caret=\(caret)")
    }

    @Test func toolbarListAtEndOfLineKeepsCaretAtEndOfBody() {
        let plain = MarkdownRichTextCodec.attributedString(from: "创建账号", metrics: metrics)
        let end = NSRange(location: plain.length, length: 0)
        let (listed, caret) = MarkdownRichTextCodec.apply(
            .unorderedList,
            to: plain,
            selectedRange: end,
            metrics: metrics
        )
        #expect(listed.string == "• 创建账号", "got=\(listed.string)")
        #expect(caret == NSRange(location: listed.length, length: 0), "caret=\(caret)")
    }

    @Test func toolbarToggleOffRemovesBullet() {
        let base = MarkdownRichTextCodec.attributedString(from: "- 可能", metrics: metrics)
        #expect(base.string.hasPrefix("•"))
        let (off, _) = MarkdownRichTextCodec.apply(
            .unorderedList,
            to: base,
            selectedRange: NSRange(location: 0, length: 1),
            metrics: metrics
        )
        #expect(off.string == "可能" || off.string.hasPrefix("可能"), "got=\(off.string)")
        #expect(!off.string.hasPrefix("•"))
    }

    // MARK: Round-trip storage

    @Test func bulletRoundTripToMarkdownDash() {
        let rich = MarkdownRichTextCodec.attributedString(from: "- 可能\n- 你", metrics: metrics)
        #expect(rich.string.contains("• 可能"))
        let md = MarkdownRichTextCodec.markdown(from: rich)
        #expect(md.contains("- 可能"), "md=\(md)")
        #expect(md.contains("- 你"), "md=\(md)")
        #expect(!md.contains("•"), "storage should be markdown dash not bullet glyph; md=\(md)")
    }

    @Test func orderedRoundTrip() {
        let rich = MarkdownRichTextCodec.attributedString(from: "1. 一\n2. 二", metrics: metrics)
        let md = MarkdownRichTextCodec.markdown(from: rich)
        #expect(md.contains("1. 一"), "md=\(md)")
        #expect(md.contains("2. 二"), "md=\(md)")
    }

    @Test func boldToggleLeavesNoMarkersInEditor() {
        let base = MarkdownRichTextCodec.attributedString(from: "hello world", metrics: metrics)
        let (bolded, _) = MarkdownRichTextCodec.apply(
            .bold,
            to: base,
            selectedRange: NSRange(location: 0, length: 5),
            metrics: metrics
        )
        #expect(bolded.string == "hello world")
        #expect(!bolded.string.contains("*"))
        let md = MarkdownRichTextCodec.markdown(from: bolded)
        #expect(md.contains("**hello**"), "md=\(md)")
    }

    @Test func typingOrderedPrefixAloneDoesNotWipeWhenConvertedOnce() {
        // User typed only "1. " as a paragraph (not yet a rich ordered block).
        let typed = NSMutableAttributedString(
            string: "1. ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .notesBlock: NotesBlockKind.paragraph.rawValue
            ]
        )
        let (listed, _) = MarkdownRichTextCodec.apply(
            .orderedList,
            to: typed,
            selectedRange: NSRange(location: 3, length: 0),
            metrics: metrics
        )
        // Must keep the marker, not become empty.
        #expect(listed.string == "1. " || listed.string.hasPrefix("1."), "got=\(listed.string)")
        #expect(!listed.string.isEmpty)

        // Second apply toggles OFF but should leave the body (empty body → empty line OK,
        // but must not crash / must be deterministic).
        let (off, _) = MarkdownRichTextCodec.apply(
            .orderedList,
            to: listed,
            selectedRange: NSRange(location: 0, length: 0),
            metrics: metrics
        )
        // After toggle off of empty-bodied ordered line, result is empty string — OK.
        // Critical: first conversion must not have cleared before user typed body.
        #expect(listed.string.hasPrefix("1."))
        _ = off
    }

    @Test func checklistToggleChecked() {
        let base = MarkdownRichTextCodec.attributedString(from: "- [ ] 任务", metrics: metrics)
        #expect(base.string.contains("☐"))
        guard let toggled = MarkdownRichTextCodec.toggleChecklistChecked(
            in: base,
            at: 0,
            metrics: metrics
        ) else {
            Issue.record("toggle failed")
            return
        }
        #expect(toggled.string.contains("☑"))
        let md = MarkdownRichTextCodec.markdown(from: toggled)
        #expect(md.contains("- [x]"), "md=\(md)")
    }
}
