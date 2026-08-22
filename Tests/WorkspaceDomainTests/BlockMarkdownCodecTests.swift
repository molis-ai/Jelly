import Foundation
import Testing
import WorkspaceDomain

private enum ContinuationToken {
    static let soft = "<!--jelly:continue-soft:v1-->"
    static let hard = "<!--jelly:continue-hard:v1-->"
    static let reservedPrefix = "<!--jelly:continue-"
}

private enum SpanManifestToken {
    static let blockLink = "<!--jelly:block:link:v1-->"
    static let emptyContent = "<!--jelly:spans:v1;n=0-->"

    static func span(marks: String, url: String = "~") -> String {
        "<!--jelly:span:v1;m=\(marks);u=\(url)-->"
    }
}

@Suite("BlockMarkdownCodecTests")
struct BlockMarkdownCodecTests {
    @Test(arguments: BlockMarkdownFixture.all)
    func roundTripPreservesSupportedStructure(_ fixture: BlockMarkdownFixture) throws {
        let imported = try BlockMarkdownCodec.importMarkdown(
            fixture.markdown,
            idSource: fixture.ids,
            checkedTaskCompletedAt: fixture.checkedTaskCompletedAt
        )

        #expect(imported.diagnostics == [])
        #expect(imported.document == fixture.document)
        let canonical = try BlockMarkdownCodec.exportMarkdown(imported.document)
        #expect(canonical == fixture.canonicalMarkdown)
        let reimportedCanonical = try BlockMarkdownCodec.importMarkdown(
            canonical,
            idSource: fixture.ids,
            checkedTaskCompletedAt: fixture.checkedTaskCompletedAt
        )
        #expect(reimportedCanonical.diagnostics == [])
        #expect(reimportedCanonical.document == fixture.document)
    }

    @Test func checkedTasksUseOneInjectedTimestampAndUncheckedTasksStayNil() throws {
        let completedAt = Date(timeIntervalSince1970: 1_786_320_400)
        let result = try BlockMarkdownCodec.importMarkdown(
            "- [x] 第一项\n- [ ] 第二项\n- [X] 第三项",
            idSource: .fixed(Self.ids(count: 3, start: 100)),
            checkedTaskCompletedAt: completedAt
        )

        #expect(result.document.blocks.map(\.taskState?.completedAt) == [completedAt, nil, completedAt])
        let markdown = try BlockMarkdownCodec.exportMarkdown(result.document)
        #expect(markdown.contains("- [x] 第一项"))
        #expect(markdown.contains("- [ ] 第二项"))
        #expect(markdown.contains("- [x] 第三项"))
        #expect(markdown.components(separatedBy: "<!--jelly:span:v1;").count == 4)
    }

    @Test func exportingCompletedTimestampAndReimportingUsesInjectedTimestampInstead() throws {
        let originalCompletion = Date(timeIntervalSince1970: 1_786_320_400)
        let importedCompletion = Date(timeIntervalSince1970: 1_786_420_400)
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000901")!)
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000902")!
        let original = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 101)[0],
                kind: .task,
                inlineContent: .plain("已完成"),
                taskState: .init(completedAt: originalCompletion),
                indentLevel: 0,
                codeInfoString: nil
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(original)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 101)),
            checkedTaskCompletedAt: importedCompletion
        ).document
        let originalNote = Note(
            id: noteID,
            title: "完成状态",
            document: original,
            categoryID: categoryID,
            archivedAt: nil,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let reimportedNote = Note(
            id: noteID,
            title: "完成状态",
            document: reimported,
            categoryID: categoryID,
            archivedAt: nil,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        #expect(markdown.hasPrefix("- [x] 已完成<!--jelly:span:v1;"))
        #expect(reimported.blocks[0].taskState?.completedAt == importedCompletion)
        #expect(reimported.blocks[0].taskState?.completedAt != originalCompletion)
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(originalNote) != WorkspaceChecksum.noteSnapshotChecksum(reimportedNote))
    }

    @Test func codeInfoUsesTildeFenceWhenItContainsBacktickAndExtendsDelimiterRuns() throws {
        let result = try BlockMarkdownCodec.importMarkdown(
            "~~~swift`dialect\nlet marker = ~~~\n~~~~~\n",
            idSource: .fixed(Self.ids(count: 1, start: 200)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks[0].codeInfoString == "swift`dialect")
        #expect(result.document.blocks[0].inlineContent == .plain("let marker = ~~~"))
        #expect(try BlockMarkdownCodec.exportMarkdown(result.document) == "~~~~swift`dialect\nlet marker = ~~~\n~~~~")
    }

    @Test func codeInfoStringSurvivesMarkdownModelMarkdownModelRoundTrip() throws {
        let completionTime = Date(timeIntervalSince1970: 1_786_320_400)
        let first = try BlockMarkdownCodec.importMarkdown(
            "```swift linenums=1\nlet fence = ```\n```",
            idSource: .fixed(Self.ids(count: 1, start: 250)),
            checkedTaskCompletedAt: completionTime
        ).document
        let exported = try BlockMarkdownCodec.exportMarkdown(first)
        let second = try BlockMarkdownCodec.importMarkdown(
            exported,
            idSource: .fixed(Self.ids(count: 1, start: 251)),
            checkedTaskCompletedAt: completionTime
        ).document

        #expect(exported == "````swift linenums=1\nlet fence = ```\n````")
        #expect(second.blocks[0].codeInfoString == "swift linenums=1")
        #expect(second.blocks[0].inlineContent == first.blocks[0].inlineContent)
    }

    @Test func unsupportedMarkdownProducesLineDiagnosticWithoutDroppingCharacters() throws {
        let markdown = "| 标题 |\n| --- |\n| 内容 |"
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 300)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 300)[0],
                kind: .paragraph,
                inlineContent: .plain(markdown),
                taskState: nil,
                indentLevel: 0,
                codeInfoString: nil
            )
        ])
        #expect(result.diagnostics == [.init(lineNumber: 1, message: "不支持的 Markdown 表格已保留为正文")])
    }

    @Test func deeperListIndentClampsAtThreeAndKeepsExcessSpacesAsText() throws {
        let markdown = "- 一级\n    - 二级\n        - 三级\n            - 四级\n                - 五级"
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 5, start: 400)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks.map(\.indentLevel) == [0, 1, 2, 3, 3])
        #expect(result.document.blocks[4].inlineContent == .plain("    五级"))
        let canonical = try BlockMarkdownCodec.exportMarkdown(result.document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            canonical,
            idSource: .fixed(Self.ids(count: 5, start: 400)),
            checkedTaskCompletedAt: .distantPast
        )
        #expect(reimported.document == result.document)
    }

    @Test func importDegradesOrphanedListToDiagnosedValidatedParagraph() throws {
        let source = "    - orphan"
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(Self.ids(count: 1, start: 500)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 500)[0],
                kind: .paragraph,
                inlineContent: .plain(source),
                taskState: nil,
                indentLevel: 0
            )
        ])
        #expect(result.diagnostics == [.init(lineNumber: 1, message: "孤立的列表缩进已保留为正文")])
        try BlockDocumentValidator.validate(result.document)
        #expect(try BlockMarkdownCodec.exportMarkdown(result.document).hasPrefix("\\    - orphan"))
    }

    @Test func paragraphExportEscapesLeadingBlockSyntaxForKindRoundTrip() throws {
        let document = BlockDocument(blocks: [
            .init(id: Self.ids(count: 1, start: 510)[0], kind: .paragraph, inlineContent: .plain("# 不是标题"), taskState: nil, indentLevel: 0),
            .init(id: Self.ids(count: 1, start: 511)[0], kind: .paragraph, inlineContent: .plain("正文\n---"), taskState: nil, indentLevel: 0)
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 3, start: 510)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown.hasPrefix("\\# 不是标题<!--jelly:span:v1;"))
        #expect(markdown.contains(ContinuationToken.soft))
        #expect(reimported == document)
    }

    @Test func inlineLinkMarksAndParagraphKindSurviveRoundTrip() throws {
        let url = URL(string: "https://example.com/important")!
        let content = InlineContent(spans: [.init(text: "重要", marks: [.bold], linkURL: url)])
        let document = BlockDocument(blocks: [
            .init(id: Self.ids(count: 1, start: 520)[0], kind: .paragraph, inlineContent: content, taskState: nil, indentLevel: 0),
            .init(id: Self.ids(count: 1, start: 521)[0], kind: .link, inlineContent: content, taskState: nil, indentLevel: 0)
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 2, start: 520)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown.contains(SpanManifestToken.blockLink))
        #expect(markdown.components(separatedBy: "<!--jelly:span:v1;").count == 3)
        #expect(reimported == document)
    }

    @Test func exportUsesContinuationTokensAndNeverLeavesTrailingWhitespace() throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 530)[0],
                kind: .paragraph,
                inlineContent: .plain("a  \nb "),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 530)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == "a\(ContinuationToken.hard)\nb \(SpanManifestToken.span(marks: "~"))")
        #expect(!markdown.components(separatedBy: "\n").contains { line in
            line.hasSuffix(" ") || line.hasSuffix("\t")
        })
        #expect(reimported.blocks[0].inlineContent == .plain("a  \nb "))
    }

    @Test func exportKeepsTerminalWhitespaceInsideTheFollowingSpanManifest() throws {
        let document = BlockDocument(blocks: [
            .init(id: Self.ids(count: 1, start: 535)[0], kind: .heading1, inlineContent: .plain("标题 "), taskState: nil, indentLevel: 0),
            .init(id: Self.ids(count: 1, start: 536)[0], kind: .bullet, inlineContent: .plain("项目\t"), taskState: nil, indentLevel: 0),
            .init(id: Self.ids(count: 1, start: 537)[0], kind: .quote, inlineContent: .plain("引用 "), taskState: nil, indentLevel: 0)
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)

        #expect(markdown.contains("# 标题 \(SpanManifestToken.span(marks: "~"))"))
        #expect(markdown.contains("- 项目\t\(SpanManifestToken.span(marks: "~"))"))
        #expect(markdown.contains("> 引用 \(SpanManifestToken.span(marks: "~"))"))
        #expect(!markdown.components(separatedBy: "\n").contains { line in
            line.hasSuffix(" ") || line.hasSuffix("\t")
        })
    }

    @Test func escapedInlineLinkDelimitersKeepLinkBlockAndCombinedMarks() throws {
        let url = URL(string: "https://example.com/escapes")!
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 560)[0],
                kind: .link,
                inlineContent: .init(spans: [.init(text: "A]B)\\C", marks: [.bold, .italic], linkURL: url)]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 560)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown.hasPrefix(SpanManifestToken.blockLink + "[***A\\]B\\)\\\\C***](<https://example.com/escapes>)"))
        #expect(reimported == document)
    }

    @Test func quoteHardBreakUsesSharedInlineNormalizationForRoundTrip() throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 570)[0],
                kind: .quote,
                inlineContent: .plain("a  \nb"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 570)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == "> a\(ContinuationToken.hard)\n> b\(SpanManifestToken.span(marks: "~"))")
        #expect(reimported == document)
    }

    @Test(arguments: MultilineProseFixture.all)
    func everySupportedProseKindRoundTripsSoftAndHardLineBreaks(_ fixture: MultilineProseFixture) throws {
        let markdown = try BlockMarkdownCodec.exportMarkdown(fixture.document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed([fixture.document.blocks[0].id, BlockID(), BlockID()]),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == fixture.canonicalMarkdown)
        #expect(reimported == fixture.document)
    }

    @Test func linkLabelsPreserveBoundaryWhitespaceAndMultilineCombinedMarks() throws {
        let url = URL(string: "https://example.com/labels")!
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 620)[0],
                kind: .link,
                inlineContent: .init(spans: [.init(text: "A ", linkURL: url)]),
                taskState: nil,
                indentLevel: 0
            ),
            .init(
                id: Self.ids(count: 1, start: 621)[0],
                kind: .link,
                inlineContent: .init(spans: [.init(text: " A\nB ", marks: [.bold, .italic], linkURL: url)]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 2, start: 620)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown.hasPrefix(SpanManifestToken.blockLink))
        #expect(markdown.components(separatedBy: SpanManifestToken.blockLink).count == 3)
        #expect(reimported == document)
    }

    @Test(arguments: ContinuationParityFixture.all)
    func continuationTokenParityDistinguishesActiveAndLiteralTokens(_ fixture: ContinuationParityFixture) throws {
        let result = try BlockMarkdownCodec.importMarkdown(
            fixture.markdown,
            idSource: .fixed(Self.ids(count: 1, start: 700)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.diagnostics == [])
        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 700)[0],
                kind: .paragraph,
                inlineContent: .plain(fixture.expectedText),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }

    @Test(arguments: LiteralContinuationExportFixture.all)
    func exportEscapesLiteralContinuationTokensWithoutChangingTheirModelText(_ fixture: LiteralContinuationExportFixture) throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 710)[0],
                kind: .paragraph,
                inlineContent: .plain(fixture.modelText),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 710)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == fixture.canonicalMarkdown + SpanManifestToken.span(marks: "~"))
        #expect(reimported == document)
    }

    @Test func malformedContinuationPrefixesRemainVerbatimAndAreDiagnosed() throws {
        let malformed = "A<!--jelly:continue-soft:v1--> \nB\nC\(ContinuationToken.reservedPrefix)x-->"
        let result = try BlockMarkdownCodec.importMarkdown(
            malformed,
            idSource: .fixed(Self.ids(count: 1, start: 720)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks[0].inlineContent == .plain(malformed))
        #expect(result.diagnostics.map(\.lineNumber) == [1, 3])

        let mixed = try BlockMarkdownCodec.importMarkdown(
            "A\(ContinuationToken.reservedPrefix)x-->\(ContinuationToken.soft)",
            idSource: .fixed(Self.ids(count: 1, start: 721)),
            checkedTaskCompletedAt: .distantPast
        )
        #expect(mixed.document.blocks[0].inlineContent == .plain("A\(ContinuationToken.reservedPrefix)x-->\n"))
        #expect(mixed.diagnostics.map(\.lineNumber) == [1])
    }

    @Test(arguments: UnmarkedBoundaryFixture.all)
    func unmarkedBoundariesDoNotGuessContinuationFromTheNextLine(_ fixture: UnmarkedBoundaryFixture) throws {
        let result = try BlockMarkdownCodec.importMarkdown(
            fixture.markdown,
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks.map(\.kind) == [fixture.leadingKind, fixture.followingKind])
    }

    @Test func noMarkerHeadingThenParagraphAndMultilineLinkRemainSeparateBlocks() throws {
        let paragraphResult = try BlockMarkdownCodec.importMarkdown(
            "# 标题\n正文",
            idSource: .fixed(Self.ids(count: 2, start: 730)),
            checkedTaskCompletedAt: .distantPast
        )
        let linkResult = try BlockMarkdownCodec.importMarkdown(
            "# 标题\n[A\nB](https://example.com/multiline)",
            idSource: .fixed(Self.ids(count: 2, start: 732)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(paragraphResult.document.blocks.map(\.kind) == [.heading1, .paragraph])
        #expect(paragraphResult.document.blocks.map(\.inlineContent) == [.plain("标题"), .plain("正文")])
        #expect(linkResult.document.blocks.map(\.kind) == [.heading1, .link])
        guard linkResult.document.blocks.count == 2 else { return }
        #expect(linkResult.document.blocks[1].inlineContent.spans == [.init(text: "A\nB", linkURL: URL(string: "https://example.com/multiline")!)])
    }

    @Test func markedContinuationConsumesBlankAndEveryBlockMarkerAsCurrentContent() throws {
        let markers = [
            "# heading", "## heading", "### heading", "- bullet", "1. ordered", "- [x] task",
            "> quote", "```swift", "---", "[link](https://example.com/link)", "| unsupported |"
        ]
        for marker in markers {
            let result = try BlockMarkdownCodec.importMarkdown(
                "# first\(ContinuationToken.soft)\n\(marker)",
                checkedTaskCompletedAt: .distantPast
            )
            #expect(result.document.blocks.count == 1)
            #expect(result.document.blocks[0].kind == .heading1)
            #expect(result.diagnostics == [])
        }

        let blankResult = try BlockMarkdownCodec.importMarkdown(
            "# first\(ContinuationToken.soft)\n\(ContinuationToken.soft)\nlast",
            idSource: .fixed(Self.ids(count: 1, start: 740)),
            checkedTaskCompletedAt: .distantPast
        )
        #expect(blankResult.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 740)[0],
                kind: .heading1,
                inlineContent: .plain("first\n\nlast"),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }

    @Test(arguments: ProseContinuationWhitespaceFixture.all)
    func proseContinuationEncodingPreservesContentWhitespaceBeforeEveryBlockPrefix(
        _ fixture: ProseContinuationWhitespaceFixture
    ) throws {
        let document = fixture.document(id: Self.ids(count: 1, start: 760)[0])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 760)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == fixture.canonicalMarkdown)
        #expect(reimported == document)
        #expect(!markdown.components(separatedBy: "\n").contains { $0.hasSuffix(" ") || $0.hasSuffix("\t") })
    }

    @Test func blankWithoutItsOwnContinuationTokenEndsParagraphQuoteAndMultilineLink() throws {
        let paragraph = try BlockMarkdownCodec.importMarkdown(
            "A\(ContinuationToken.soft)\n\n# B",
            idSource: .fixed(Self.ids(count: 2, start: 800)),
            checkedTaskCompletedAt: .distantPast
        )
        let quote = try BlockMarkdownCodec.importMarkdown(
            "> A\(ContinuationToken.soft)\n\n> B",
            idSource: .fixed(Self.ids(count: 2, start: 802)),
            checkedTaskCompletedAt: .distantPast
        )
        let malformedLink = try BlockMarkdownCodec.importMarkdown(
            "[A\n\nB](https://example.com/blank)",
            idSource: .fixed(Self.ids(count: 2, start: 804)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(paragraph.document.blocks.map(\.kind) == [.paragraph, .heading1])
        #expect(paragraph.document.blocks.map(\.inlineContent) == [.plain("A\n"), .plain("B")])
        #expect(quote.document.blocks.map(\.kind) == [.quote, .quote])
        #expect(quote.document.blocks.map(\.inlineContent) == [.plain("A\n"), .plain("B")])
        #expect(malformedLink.document.blocks.map(\.kind) == [.paragraph, .paragraph])
        #expect(malformedLink.document.blocks.map(\.inlineContent) == [.plain("[A"), .plain("B](https://example.com/blank)")])
        #expect(malformedLink.diagnostics.map(\.lineNumber) == [1])
    }

    @Test func standaloneLinkTerminalContinuationConsumesExactlyItsNextPhysicalLine() throws {
        let url = URL(string: "https://example.com/continued")!
        let continued = try BlockMarkdownCodec.importMarkdown(
            "[A](https://example.com/continued)\(ContinuationToken.soft)\n# next\n正文",
            idSource: .fixed(Self.ids(count: 3, start: 810)),
            checkedTaskCompletedAt: .distantPast
        )
        let eof = try BlockMarkdownCodec.importMarkdown(
            "[A](https://example.com/continued)\(ContinuationToken.soft)",
            idSource: .fixed(Self.ids(count: 1, start: 812)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(continued.document.blocks.map(\.kind) == [.link, .paragraph])
        #expect(continued.document.blocks[0].inlineContent.spans == [.init(text: "A\n# next", linkURL: url)])
        #expect(continued.document.blocks[1].inlineContent == .plain("正文"))
        #expect(eof.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 812)[0],
                kind: .link,
                inlineContent: .init(spans: [.init(text: "A\n", linkURL: url)]),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }

    @Test func multilineInlineCodePreservesRawCodeTextWhileEncodingItsLineBreak() throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 820)[0],
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "a*\nB", marks: [.code])]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 820)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == "`a*\(ContinuationToken.soft)\nB`\(SpanManifestToken.span(marks: "c"))")
        #expect(reimported == document)
    }

    @Test func unmarkedListAndTaskSiblingChildParentTransitionsKeepAllIndentLevels() throws {
        let result = try BlockMarkdownCodec.importMarkdown(
            "- root\n    - [ ] child task\n        1. grandchild\n            - [x] deep task\n            - deep sibling\n        1. parent sibling\n    - [ ] root child sibling\n- root sibling",
            idSource: .fixed(Self.ids(count: 8, start: 750)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.diagnostics == [])
        #expect(result.document.blocks.map(\.kind) == [.bullet, .task, .ordered, .task, .bullet, .ordered, .task, .bullet])
        #expect(result.document.blocks.map(\.indentLevel) == [0, 1, 2, 3, 3, 2, 1, 0])
        #expect(result.document.blocks.map(\.taskState?.completedAt) == [nil, nil, nil, .distantPast, nil, nil, nil, nil])
    }

    @Test func backtickFenceInfoIsDiagnosedAndPreservedAsParagraph() throws {
        let source = "```swift`dialect\nlet value = 1\n```"
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(Self.ids(count: 1, start: 540)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 540)[0],
                kind: .paragraph,
                inlineContent: .plain(source),
                taskState: nil,
                indentLevel: 0
            )
        ])
        #expect(result.diagnostics == [.init(lineNumber: 1, message: "不支持的代码围栏信息已保留为正文")])
        try BlockDocumentValidator.validate(result.document)
    }

    @Test func importDegradesNULCodeInfoToDiagnosedValidatedParagraph() throws {
        let source = "```swift\u{0000}\nlet value = 1\n```"
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(Self.ids(count: 1, start: 550)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 550)[0],
                kind: .paragraph,
                inlineContent: .plain(source),
                taskState: nil,
                indentLevel: 0
            )
        ])
        #expect(result.diagnostics == [.init(lineNumber: 1, message: "无效的代码围栏信息已保留为正文")])
        try BlockDocumentValidator.validate(result.document)
    }

    // RED for Task 2R: a future accidental return to a post-render continuation
    // rewriter would lose either wrapper ownership or exact span segmentation.
    @Test(arguments: SpanAwareInlineFixture.markMatrix)
    func spanAwareSerializerKeepsEveryMarkedSpanAndItsContinuationInsideTheWrapper(
        _ fixture: SpanAwareInlineFixture
    ) throws {
        let document = fixture.document(id: Self.ids(count: 1, start: 900)[0])
        try BlockDocumentValidator.validate(document)

        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 900)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(markdown == fixture.expectedMarkdown)
        #expect(!markdown.hasSuffix("\n"))
        #expect(!markdown.components(separatedBy: "\n").contains { $0.hasSuffix(" ") || $0.hasSuffix("\t") })
        #expect(reimported.diagnostics == [])
        #expect(reimported.document == document)
    }

    @Test func spanManifestsPreserveEmptyAdjacentMixedLinkAndZeroSpanShapesExactly() throws {
        let firstURL = URL(string: "https://example.com/a")!
        let secondURL = URL(string: "https://example.com/b")!
        let documents: [(BlockDocument, String)] = [
            (
                .init(blocks: [
                    .init(
                        id: Self.ids(count: 1, start: 910)[0],
                        kind: .paragraph,
                        inlineContent: .init(spans: [
                            .init(text: "A"),
                            .init(text: "B"),
                            .init(text: "", marks: [.bold]),
                            .init(text: "", marks: [.italic], linkURL: firstURL),
                            .init(text: "C", linkURL: firstURL),
                            .init(text: "D", linkURL: nil),
                            .init(text: "E", linkURL: secondURL)
                        ]),
                        taskState: nil,
                        indentLevel: 0
                    )
                ]),
                "A\(SpanManifestToken.span(marks: "~"))B\(SpanManifestToken.span(marks: "~"))\(SpanManifestToken.span(marks: "b"))\(SpanManifestToken.span(marks: "i", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS9h"))[C](<https://example.com/a>)\(SpanManifestToken.span(marks: "~", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS9h"))D\(SpanManifestToken.span(marks: "~"))[E](<https://example.com/b>)\(SpanManifestToken.span(marks: "~", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS9i"))"
            ),
            (
                .init(blocks: [
                    .init(
                        id: Self.ids(count: 1, start: 911)[0],
                        kind: .paragraph,
                        inlineContent: .init(spans: []),
                        taskState: nil,
                        indentLevel: 0
                    )
                ]),
                SpanManifestToken.emptyContent
            ),
            (
                .init(blocks: [
                    .init(
                        id: Self.ids(count: 1, start: 912)[0],
                        kind: .link,
                        inlineContent: .init(spans: [
                            .init(text: "A", marks: [.bold], linkURL: firstURL),
                            .init(text: "B", marks: [.italic], linkURL: secondURL),
                            .init(text: "", marks: [.code], linkURL: firstURL)
                        ]),
                        taskState: nil,
                        indentLevel: 0
                    )
                ]),
                "\(SpanManifestToken.blockLink)[**A**](<https://example.com/a>)\(SpanManifestToken.span(marks: "b", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS9h"))[*B*](<https://example.com/b>)\(SpanManifestToken.span(marks: "i", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS9i"))\(SpanManifestToken.span(marks: "c", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS9h"))"
            )
        ]

        for (document, expectedMarkdown) in documents {
            try BlockDocumentValidator.validate(document)
            let markdown = try BlockMarkdownCodec.exportMarkdown(document)
            let imported = try BlockMarkdownCodec.importMarkdown(
                markdown,
                idSource: .fixed(document.blocks.map(\.id)),
                checkedTaskCompletedAt: .distantPast
            )
            #expect(markdown == expectedMarkdown)
            #expect(imported.diagnostics == [])
            #expect(imported.document == document)
        }
    }

    @Test func spanOwnedHardAndSoftBreaksUseBothLogicalEOLBranchesWithoutMovingTheLF() throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 920)[0],
                kind: .paragraph,
                inlineContent: .init(spans: [
                    .init(text: "same  \nline", marks: [.bold]),
                    .init(text: "split  "),
                    .init(text: "\nend", marks: [.italic]),
                    .init(text: "terminal\n", marks: [.code]),
                    .init(text: "", marks: [.bold])
                ]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let expected = "**same\(ContinuationToken.hard)\nline**\(SpanManifestToken.span(marks: "b"))split  \(SpanManifestToken.span(marks: "~"))*\(ContinuationToken.soft)\nend*\(SpanManifestToken.span(marks: "i"))`terminal\(ContinuationToken.soft)`\(SpanManifestToken.span(marks: "c"))\n\(SpanManifestToken.span(marks: "b"))"

        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let imported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 920)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(markdown == expected)
        #expect(!markdown.hasSuffix("\n"))
        #expect(imported.diagnostics == [])
        #expect(imported.document == document)
    }

    @Test(arguments: [0, 1, 2, 3])
    func inlineCodeControlParityIsReversibleForActiveAndLiteralControls(_ backslashCount: Int) throws {
        let backslashes = String(repeating: "\\", count: backslashCount)
        let source = "`A\(backslashes)\(ContinuationToken.soft)\nB`\(SpanManifestToken.span(marks: "c"))"
        let expectedText = backslashCount.isMultiple(of: 2)
            ? "A\(String(repeating: "\\", count: backslashCount / 2))\nB"
            : "A\(String(repeating: "\\", count: (backslashCount - 1) / 2))\(ContinuationToken.soft)\nB"
        let expected = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 930)[0],
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: expectedText, marks: [.code])]),
                taskState: nil,
                indentLevel: 0
            )
        ])

        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(Self.ids(count: 1, start: 930)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.diagnostics == [])
        #expect(result.document == expected)
    }

    @Test func malformedAndMismatchedSpanControlsRemainRawAndDiagnosed() throws {
        let malformed = "A<!--jelly:span:v1;m=bold;u=~-->"
        let mismatch = "**A**\(SpanManifestToken.span(marks: "i"))"

        for source in [malformed, mismatch] {
            let result = try BlockMarkdownCodec.importMarkdown(
                source,
                idSource: .fixed(Self.ids(count: 1, start: 940)),
                checkedTaskCompletedAt: .distantPast
            )
            #expect(result.document.blocks == [
                .init(
                    id: Self.ids(count: 1, start: 940)[0],
                    kind: .paragraph,
                    inlineContent: .plain(source),
                    taskState: nil,
                    indentLevel: 0
                )
            ])
            #expect(result.diagnostics.map(\.lineNumber) == [1])
        }
    }

    @Test func spanTerminalEOLStopsBeforeTheFollowingListBlock() throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 950)[0],
                kind: .bullet,
                inlineContent: .plain("A\n"),
                taskState: nil,
                indentLevel: 0
            ),
            .init(
                id: Self.ids(count: 1, start: 951)[0],
                kind: .bullet,
                inlineContent: .plain("B"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let expected = "- A\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))\n\n- B\(SpanManifestToken.span(marks: "~"))"

        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(document.blocks.map(\.id)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(markdown == expected)
        #expect(result.diagnostics == [])
        #expect(result.document == document)
    }

    @Test func terminalListSpanSeparatorKeepsItsNestedListContext() throws {
        let ids = Self.ids(count: 2, start: 970)
        let document = BlockDocument(blocks: [
            .init(
                id: ids[0],
                kind: .bullet,
                inlineContent: .plain("A\n"),
                taskState: nil,
                indentLevel: 0
            ),
            .init(
                id: ids[1],
                kind: .bullet,
                inlineContent: .plain("B"),
                taskState: nil,
                indentLevel: 1
            )
        ])
        let expected = "- A\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))\n\n" +
            "    - B\(SpanManifestToken.span(marks: "~"))"

        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(ids),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(markdown == expected)
        #expect(result.diagnostics == [])
        #expect(result.document == document)
    }

    @Test func unmarkedBlankListSeparatorStillResetsNestedListContext() throws {
        let ids = Self.ids(count: 2, start: 972)
        let source = "- A\n\n    - B"
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(ids),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: ids[0],
                kind: .bullet,
                inlineContent: .plain("A"),
                taskState: nil,
                indentLevel: 0
            ),
            .init(
                id: ids[1],
                kind: .paragraph,
                inlineContent: .plain("    - B"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        #expect(result.diagnostics.map(\.lineNumber) == [3])
    }

    @Test(arguments: SpanTerminalBlockMarkerFixture.all)
    func spanTerminalContinuesAFollowingSpanStartingWithEveryBlockMarker(
        _ fixture: SpanTerminalBlockMarkerFixture
    ) throws {
        let id = Self.ids(count: 1, start: 963)[0]
        let document = BlockDocument(blocks: [
            .init(
                id: id,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "A\n"), fixture.nextSpan]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let expected = "A\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))\n" +
            fixture.serializedNextSpan

        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed([id]),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(markdown == expected)
        #expect(result.diagnostics == [])
        #expect(result.document == document)
    }

    @Test(arguments: SpanTerminalBlockMarkerFixture.all)
    func blankSeparatorKeepsTheSameMarkerAsANewCanonicalBlock(
        _ fixture: SpanTerminalBlockMarkerFixture
    ) throws {
        let ids = Self.ids(count: 2, start: 964)
        let document = BlockDocument(blocks: [
            .init(
                id: ids[0],
                kind: .paragraph,
                inlineContent: .plain("A\n"),
                taskState: nil,
                indentLevel: 0
            ),
            fixture.followingBlock(id: ids[1])
        ])
        let expected = "A\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))\n\n" +
            fixture.serializedFollowingBlock

        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(ids),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(markdown == expected)
        #expect(result.diagnostics == [])
        #expect(result.document == document)
    }

    @Test func standaloneLinkInternalEOLStopsAtItsClosingDestination() throws {
        let url = URL(string: "https://example.com/continued")!
        let markdown = "[A\(ContinuationToken.soft)\nB](https://example.com/continued)\n# H"
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 2, start: 952)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.diagnostics == [])
        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 952)[0],
                kind: .link,
                inlineContent: .init(spans: [.init(text: "A\nB", linkURL: url)]),
                taskState: nil,
                indentLevel: 0
            ),
            .init(
                id: Self.ids(count: 1, start: 953)[0],
                kind: .heading1,
                inlineContent: .plain("H"),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }

    @Test func literalJellyControlsDoNotHideLaterBoundariesOrInjectManifests() throws {
        let privateControl = "<!--jelly:private:v1-->"
        let literalManifest = SpanManifestToken.span(marks: "~")
        let documents = [
            BlockDocument(blocks: [
                .init(
                    id: Self.ids(count: 1, start: 954)[0],
                    kind: .paragraph,
                    inlineContent: .plain("A\(privateControl)B\nC"),
                    taskState: nil,
                    indentLevel: 0
                )
            ]),
            BlockDocument(blocks: [
                .init(
                    id: Self.ids(count: 1, start: 955)[0],
                    kind: .paragraph,
                    inlineContent: .plain("A\(privateControl)B\(literalManifest)C"),
                    taskState: nil,
                    indentLevel: 0
                )
            ])
        ]
        let expectedMarkdown = [
            "A\\\(privateControl)B\(ContinuationToken.soft)\nC\(literalManifest)",
            "A\\\(privateControl)B\\\(literalManifest)C\(literalManifest)"
        ]

        for (document, expected) in zip(documents, expectedMarkdown) {
            let markdown = try BlockMarkdownCodec.exportMarkdown(document)
            let result = try BlockMarkdownCodec.importMarkdown(
                markdown,
                idSource: .fixed(document.blocks.map(\.id)),
                checkedTaskCompletedAt: .distantPast
            )
            #expect(markdown == expected)
            #expect(result.diagnostics == [])
            #expect(result.document == document)
        }

        let imported = try BlockMarkdownCodec.importMarkdown(
            expectedMarkdown[0],
            idSource: .fixed(Self.ids(count: 1, start: 956)),
            checkedTaskCompletedAt: .distantPast
        )
        #expect(imported.diagnostics == [])
        #expect(imported.document.blocks[0].inlineContent == .plain("A\(privateControl)B\nC"))
    }

    @Test(arguments: [0, 1, 2, 3])
    func inlineCodeExportDoublesBackslashesBeforeActiveControls(_ backslashCount: Int) throws {
        let text = "A" + String(repeating: "\\", count: backslashCount) + "\nB"
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 957)[0],
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: text, marks: [.code])]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let expected = "`A" + String(repeating: "\\", count: backslashCount * 2) +
            ContinuationToken.soft + "\nB`" + SpanManifestToken.span(marks: "c")

        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(document.blocks.map(\.id)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(markdown == expected)
        #expect(result.diagnostics == [])
        #expect(result.document == document)
    }

    @Test func codeLinkedSpanSupportsBracketTextAndBalancedURLParentheses() throws {
        let url = URL(string: "https://example.com/wiki/Foo_(bar)")!
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 958)[0],
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "A]B", marks: [.code], linkURL: url)]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let expected = "[`A]B`](<https://example.com/wiki/Foo_(bar)>)" +
            SpanManifestToken.span(marks: "c", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS93aWtpL0Zvb18oYmFyKQ")

        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(document.blocks.map(\.id)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(markdown == expected)
        #expect(result.diagnostics == [])
        #expect(result.document == document)
    }

    @Test(arguments: CanonicalLinkDestinationFixture.all)
    func canonicalLinkDestinationsRoundTripWithoutParenthesisAmbiguity(
        _ fixture: CanonicalLinkDestinationFixture
    ) throws {
        let id = Self.ids(count: 1, start: 966)[0]
        let document = BlockDocument(blocks: [
            .init(
                id: id,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "A", linkURL: fixture.url)]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let expected = "[A](<\(fixture.url.absoluteString)>)" +
            SpanManifestToken.span(marks: "~", url: fixture.manifestURL)

        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed([id]),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(markdown == expected)
        #expect(result.diagnostics == [])
        #expect(result.document == document)
    }

    @Test func escapedExternalLinkDestinationCanonicalizesToAngleForm() throws {
        let source = "[A](https://example.com/a\\)b)"
        let id = Self.ids(count: 1, start: 967)[0]
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed([id]),
            checkedTaskCompletedAt: .distantPast
        )
        let canonical = try BlockMarkdownCodec.exportMarkdown(result.document)

        #expect(result.diagnostics == [])
        #expect(result.document.blocks == [
            .init(
                id: id,
                kind: .link,
                inlineContent: .init(spans: [
                    .init(text: "A", linkURL: URL(string: "https://example.com/a)b")!)
                ]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        #expect(canonical == SpanManifestToken.blockLink +
            "[A](<https://example.com/a)b>)" +
            SpanManifestToken.span(marks: "~", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS9hKWI"))
    }

    @Test(arguments: InvalidTerminalWrapperFixture.all)
    func continuationWithOnlyClosingWrappersRemainsLiteralAndCannotConsumeTheNextLine(
        _ fixture: InvalidTerminalWrapperFixture
    ) throws {
        let ids = Self.ids(count: 2, start: 968)
        let headingText = "A\(ContinuationToken.soft)\(fixture.closingSuffix)"
        let source = "# \(headingText)\nbody"
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(ids),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: ids[0],
                kind: .heading1,
                inlineContent: .plain(headingText),
                taskState: nil,
                indentLevel: 0
            ),
            .init(
                id: ids[1],
                kind: .paragraph,
                inlineContent: .plain("body"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        #expect(result.diagnostics.contains { $0.lineNumber == 1 })
    }

    @Test func orphanLinkBlockMarkerRemainsParagraphTextAndIsDiagnosed() throws {
        let source = "\(SpanManifestToken.blockLink)[A](https://example.com/a)"
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(Self.ids(count: 1, start: 959)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 959)[0],
                kind: .paragraph,
                inlineContent: .plain(source),
                taskState: nil,
                indentLevel: 0
            )
        ])
        #expect(result.diagnostics.map(\.lineNumber) == [1])
    }

    @Test func paragraphBlockEscapeIsRemovedBeforeManifestWrapperValidation() throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 960)[0],
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "a``b", marks: [.code])]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let expected = "\\```a``b```\(SpanManifestToken.span(marks: "c"))"

        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(document.blocks.map(\.id)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(markdown == expected)
        #expect(result.diagnostics == [])
        #expect(result.document == document)
    }

    @Test func manifestedImportScalesLinearlyWithPayloadSize() throws {
        func importDuration(size: Int) throws -> TimeInterval {
            let source = String(repeating: "a", count: size) + SpanManifestToken.span(marks: "~")
            var best = TimeInterval.greatestFiniteMagnitude
            for _ in 0..<3 {
                let start = Date.timeIntervalSinceReferenceDate
                let result = try BlockMarkdownCodec.importMarkdown(
                    source,
                    idSource: .fixed(Self.ids(count: 1, start: 961)),
                    checkedTaskCompletedAt: .distantPast
                )
                best = min(best, Date.timeIntervalSinceReferenceDate - start)
                #expect(result.document.blocks[0].inlineContent == .plain(String(repeating: "a", count: size)))
            }
            return best
        }

        _ = try importDuration(size: 256)
        let small = try importDuration(size: 2_000)
        let large = try importDuration(size: 16_000)

        #expect(large < small * 20)
    }

    @Test func unmatchedBacktickLinkLabelImportScalesLinearly() throws {
        func importDuration(size: Int) throws -> TimeInterval {
            let source = "[" + String(repeating: "`", count: size)
            var best = TimeInterval.greatestFiniteMagnitude
            for _ in 0..<4 {
                let start = Date.timeIntervalSinceReferenceDate
                let result = try BlockMarkdownCodec.importMarkdown(
                    source,
                    idSource: .fixed(Self.ids(count: 1, start: 969)),
                    checkedTaskCompletedAt: .distantPast
                )
                best = min(best, Date.timeIntervalSinceReferenceDate - start)
                #expect(result.document.blocks[0].inlineContent == .plain(source))
            }
            return best
        }

        _ = try importDuration(size: 500)
        _ = try importDuration(size: 1_000)
        let small = try importDuration(size: 2_000)
        let large = try importDuration(size: 4_000)

        #expect(large < small * 3.2)
    }

    @Test func repeatedUnmatchedLinkOpenersImportScalesLinearlyAndStayVerbatim() throws {
        func importDuration(size: Int) throws -> TimeInterval {
            let source = String(repeating: "[", count: size)
            var best = TimeInterval.greatestFiniteMagnitude
            for _ in 0..<3 {
                let start = Date.timeIntervalSinceReferenceDate
                let result = try BlockMarkdownCodec.importMarkdown(
                    source,
                    idSource: .fixed(Self.ids(count: 1, start: 974)),
                    checkedTaskCompletedAt: .distantPast
                )
                best = min(best, Date.timeIntervalSinceReferenceDate - start)
                #expect(result.diagnostics == [])
                #expect(result.document.blocks[0].inlineContent == .plain(source))
            }
            return best
        }

        _ = try importDuration(size: 1_000)
        let small = try importDuration(size: 2_000)
        _ = try importDuration(size: 4_000)
        let large = try importDuration(size: 8_000)

        #expect(large < small * 8)
    }

    @Test func manifestedMismatchReportsThePhysicalLineContainingItsManifest() throws {
        let source = "A\(ContinuationToken.soft)\nB\(SpanManifestToken.span(marks: "b"))"
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(Self.ids(count: 1, start: 962)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks[0].inlineContent == .plain(source))
        #expect(result.diagnostics.map(\.lineNumber) == [2])
    }

    @Test func jellyTaskCompletionMetadataRoundTripsWithoutChangingVisibleTitle() throws {
        let source = BlockDocument(blocks: [
            try .task(text: "给物业打电话", completionDescription: "拿到明确上门时间")
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(source)
        #expect(markdown.contains("<!--jelly:task-completion:v1;b64="))
        #expect(markdown.contains("- [ ] 给物业打电话"))
        #expect(!markdown.contains("拿到明确上门时间"))
        let restored = try BlockMarkdownCodec.importMarkdown(
            markdown, idSource: .fixed(source.blocks.map(\.id)), checkedTaskCompletedAt: .distantPast
        )
        #expect(restored.document == source)
        #expect(restored.diagnostics.isEmpty)
        #expect(restored.document.blocks[0].inlineContent.plainText == "给物业打电话")
    }

    @Test func jellyTaskCompletionMetadataPreservesListIndentContextAndRejectsInvalidMarkers() throws {
        let nested = BlockDocument(blocks: [
            try .task(
                id: Self.ids(count: 1, start: 1301)[0],
                text: "联系物业",
                completionDescription: "确认上门时间"
            ),
            try .task(
                id: Self.ids(count: 1, start: 1302)[0],
                text: "准备材料",
                indentLevel: 1,
                completionDescription: "带上钥匙"
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(nested)
        let restored = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(nested.blocks.map(\.id)),
            checkedTaskCompletedAt: .distantPast
        )
        #expect(restored.document == nested)
        #expect(restored.diagnostics.isEmpty)

        let payload = Data("确认上门时间".utf8).base64EncodedString()
        let ordinary = try BlockMarkdownCodec.importMarkdown(
            "- [ ] 普通任务",
            idSource: .fixed(Self.ids(count: 1, start: 1303)),
            checkedTaskCompletedAt: .distantPast
        )
        #expect(ordinary.document.blocks[0].taskState?.completionDescription == nil)

        let escaped = try BlockMarkdownCodec.importMarkdown(
            "- [ ] 转义任务\n\\<!--jelly:task-completion:v1;b64=\(payload)-->",
            idSource: .fixed(Self.ids(count: 2, start: 1304)),
            checkedTaskCompletedAt: .distantPast
        )
        #expect(escaped.document.blocks[0].taskState?.completionDescription == nil)
        #expect(escaped.document.blocks[0].inlineContent.plainText == "转义任务")

        let invalid = try BlockMarkdownCodec.importMarkdown(
            "- [ ] 失效任务\n<!--jelly:task-completion:v1;b64=@@@-->",
            idSource: .fixed(Self.ids(count: 2, start: 1306)),
            checkedTaskCompletedAt: .distantPast
        )
        #expect(invalid.document.blocks[0].taskState?.completionDescription == nil)
        #expect(invalid.document.blocks[0].inlineContent.plainText == "失效任务")
        #expect(invalid.diagnostics.map(\.message).contains("无效的 Jelly 控制标记已保留为正文"))
    }

    private static func ids(count: Int, start: Int) -> [BlockID] {
        (0..<count).map { offset in
            let value = start + offset
            let string = String(format: "00000000-0000-0000-0000-%012d", value)
            return BlockID(UUID(uuidString: string)!)
        }
    }
}

struct SpanTerminalBlockMarkerFixture: Sendable {
    let name: String
    let nextSpan: InlineSpan
    let serializedNextSpan: String
    let followingKind: BlockKind
    let followingContent: InlineContent
    let followingTaskState: TaskBlockState?
    let serializedFollowingBlock: String

    func followingBlock(id: BlockID) -> DocumentBlock {
        .init(
            id: id,
            kind: followingKind,
            inlineContent: followingContent,
            taskState: followingTaskState,
            indentLevel: 0
        )
    }

    private static let linkURL = URL(string: "https://example.com/marker")!
    private static let linkManifest = "aHR0cHM6Ly9leGFtcGxlLmNvbS9tYXJrZXI"
    private static let plainManifest = SpanManifestToken.span(marks: "~")

    static let all: [SpanTerminalBlockMarkerFixture] = [
        .init(name: "heading 1", nextSpan: .init(text: "# B"), serializedNextSpan: "# B\(plainManifest)", followingKind: .heading1, followingContent: .plain("B"), followingTaskState: nil, serializedFollowingBlock: "# B\(plainManifest)"),
        .init(name: "heading 2", nextSpan: .init(text: "## B"), serializedNextSpan: "## B\(plainManifest)", followingKind: .heading2, followingContent: .plain("B"), followingTaskState: nil, serializedFollowingBlock: "## B\(plainManifest)"),
        .init(name: "heading 3", nextSpan: .init(text: "### B"), serializedNextSpan: "### B\(plainManifest)", followingKind: .heading3, followingContent: .plain("B"), followingTaskState: nil, serializedFollowingBlock: "### B\(plainManifest)"),
        .init(name: "bullet", nextSpan: .init(text: "- B"), serializedNextSpan: "- B\(plainManifest)", followingKind: .bullet, followingContent: .plain("B"), followingTaskState: nil, serializedFollowingBlock: "- B\(plainManifest)"),
        .init(name: "ordered", nextSpan: .init(text: "1. B"), serializedNextSpan: "1. B\(plainManifest)", followingKind: .ordered, followingContent: .plain("B"), followingTaskState: nil, serializedFollowingBlock: "1. B\(plainManifest)"),
        .init(name: "task", nextSpan: .init(text: "- [ ] B"), serializedNextSpan: "- \\[ \\] B\(plainManifest)", followingKind: .task, followingContent: .plain("B"), followingTaskState: .init(completedAt: nil), serializedFollowingBlock: "- [ ] B\(plainManifest)"),
        .init(name: "quote", nextSpan: .init(text: "> B"), serializedNextSpan: "> B\(plainManifest)", followingKind: .quote, followingContent: .plain("B"), followingTaskState: nil, serializedFollowingBlock: "> B\(plainManifest)"),
        .init(name: "divider", nextSpan: .init(text: "---"), serializedNextSpan: "---\(plainManifest)", followingKind: .divider, followingContent: .plain(""), followingTaskState: nil, serializedFollowingBlock: "---"),
        .init(name: "code fence", nextSpan: .init(text: "a``b", marks: [.code]), serializedNextSpan: "```a``b```\(SpanManifestToken.span(marks: "c"))", followingKind: .code, followingContent: .plain("B"), followingTaskState: nil, serializedFollowingBlock: "```\nB\n```"),
        .init(name: "link", nextSpan: .init(text: "B", linkURL: linkURL), serializedNextSpan: "[B](<https://example.com/marker>)\(SpanManifestToken.span(marks: "~", url: linkManifest))", followingKind: .link, followingContent: .init(spans: [.init(text: "B", linkURL: linkURL)]), followingTaskState: nil, serializedFollowingBlock: "\(SpanManifestToken.blockLink)[B](<https://example.com/marker>)\(SpanManifestToken.span(marks: "~", url: linkManifest))")
    ]
}

struct CanonicalLinkDestinationFixture: Sendable {
    let name: String
    let url: URL
    let manifestURL: String

    static let all: [CanonicalLinkDestinationFixture] = [
        .init(name: "unbalanced closing parenthesis", url: URL(string: "https://example.com/a)b")!, manifestURL: "aHR0cHM6Ly9leGFtcGxlLmNvbS9hKWI"),
        .init(name: "unbalanced opening parenthesis", url: URL(string: "https://example.com/a(b")!, manifestURL: "aHR0cHM6Ly9leGFtcGxlLmNvbS9hKGI"),
        .init(name: "encoded space", url: URL(string: "https://example.com/a%20b")!, manifestURL: "aHR0cHM6Ly9leGFtcGxlLmNvbS9hJTIwYg"),
        .init(name: "encoded closing angle", url: URL(string: "https://example.com/a>b")!, manifestURL: "aHR0cHM6Ly9leGFtcGxlLmNvbS9hJTNFYg"),
        .init(name: "encoded opening angle", url: URL(string: "https://example.com/a<b")!, manifestURL: "aHR0cHM6Ly9leGFtcGxlLmNvbS9hJTNDYg")
    ]
}

struct InvalidTerminalWrapperFixture: Sendable {
    let name: String
    let closingSuffix: String

    private static let linkManifest = "aHR0cHM6Ly9leGFtcGxlLmNvbS9h"

    static let all: [InvalidTerminalWrapperFixture] = [
        .init(name: "code closer", closingSuffix: "`\(SpanManifestToken.span(marks: "c"))"),
        .init(name: "emphasis closer", closingSuffix: "**\(SpanManifestToken.span(marks: "b"))"),
        .init(name: "link closer", closingSuffix: "](https://example.com/a)\(SpanManifestToken.span(marks: "~", url: linkManifest))"),
        .init(name: "combined closers", closingSuffix: "`***](https://example.com/a)\(SpanManifestToken.span(marks: "bci", url: linkManifest))")
    ]
}

struct SpanAwareInlineFixture: Sendable {
    let name: String
    let marks: Set<InlineMark>
    let linkURL: URL?
    let text: String
    let expectedMarkdown: String

    func document(id: BlockID) -> BlockDocument {
        .init(blocks: [
            .init(
                id: id,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: text, marks: marks, linkURL: linkURL)]),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }

    private static let linkedURL = URL(string: "https://example.com/span")!
    private static let linkedURLManifest = "aHR0cHM6Ly9leGFtcGxlLmNvbS9zcGFu"

    static let markMatrix: [SpanAwareInlineFixture] = [
        .init(name: "code plain internal LF", marks: [.code], linkURL: nil, text: "A\nB", expectedMarkdown: "`A\(ContinuationToken.soft)\nB`\(SpanManifestToken.span(marks: "c"))"),
        .init(name: "code plain terminal LF", marks: [.code], linkURL: nil, text: "A\n", expectedMarkdown: "`A\(ContinuationToken.soft)`\(SpanManifestToken.span(marks: "c"))"),
        .init(name: "code linked internal LF", marks: [.code], linkURL: linkedURL, text: "A\nB", expectedMarkdown: "[`A\(ContinuationToken.soft)\nB`](<https://example.com/span>)\(SpanManifestToken.span(marks: "c", url: linkedURLManifest))"),
        .init(name: "code linked terminal LF", marks: [.code], linkURL: linkedURL, text: "A\n", expectedMarkdown: "[`A\(ContinuationToken.soft)`](<https://example.com/span>)\(SpanManifestToken.span(marks: "c", url: linkedURLManifest))"),
        .init(name: "bold plain internal LF", marks: [.bold], linkURL: nil, text: "A\nB", expectedMarkdown: "**A\(ContinuationToken.soft)\nB**\(SpanManifestToken.span(marks: "b"))"),
        .init(name: "bold plain terminal LF", marks: [.bold], linkURL: nil, text: "A\n", expectedMarkdown: "**A\(ContinuationToken.soft)**\(SpanManifestToken.span(marks: "b"))"),
        .init(name: "bold linked internal LF", marks: [.bold], linkURL: linkedURL, text: "A\nB", expectedMarkdown: "[**A\(ContinuationToken.soft)\nB**](<https://example.com/span>)\(SpanManifestToken.span(marks: "b", url: linkedURLManifest))"),
        .init(name: "bold linked terminal LF", marks: [.bold], linkURL: linkedURL, text: "A\n", expectedMarkdown: "[**A\(ContinuationToken.soft)**](<https://example.com/span>)\(SpanManifestToken.span(marks: "b", url: linkedURLManifest))"),
        .init(name: "italic plain internal LF", marks: [.italic], linkURL: nil, text: "A\nB", expectedMarkdown: "*A\(ContinuationToken.soft)\nB*\(SpanManifestToken.span(marks: "i"))"),
        .init(name: "italic plain terminal LF", marks: [.italic], linkURL: nil, text: "A\n", expectedMarkdown: "*A\(ContinuationToken.soft)*\(SpanManifestToken.span(marks: "i"))"),
        .init(name: "italic linked internal LF", marks: [.italic], linkURL: linkedURL, text: "A\nB", expectedMarkdown: "[*A\(ContinuationToken.soft)\nB*](<https://example.com/span>)\(SpanManifestToken.span(marks: "i", url: linkedURLManifest))"),
        .init(name: "italic linked terminal LF", marks: [.italic], linkURL: linkedURL, text: "A\n", expectedMarkdown: "[*A\(ContinuationToken.soft)*](<https://example.com/span>)\(SpanManifestToken.span(marks: "i", url: linkedURLManifest))"),
        .init(name: "bold italic plain internal LF", marks: [.bold, .italic], linkURL: nil, text: "A\nB", expectedMarkdown: "***A\(ContinuationToken.soft)\nB***\(SpanManifestToken.span(marks: "bi"))"),
        .init(name: "bold italic plain terminal LF", marks: [.bold, .italic], linkURL: nil, text: "A\n", expectedMarkdown: "***A\(ContinuationToken.soft)***\(SpanManifestToken.span(marks: "bi"))"),
        .init(name: "bold italic linked internal LF", marks: [.bold, .italic], linkURL: linkedURL, text: "A\nB", expectedMarkdown: "[***A\(ContinuationToken.soft)\nB***](<https://example.com/span>)\(SpanManifestToken.span(marks: "bi", url: linkedURLManifest))"),
        .init(name: "bold italic linked terminal LF", marks: [.bold, .italic], linkURL: linkedURL, text: "A\n", expectedMarkdown: "[***A\(ContinuationToken.soft)***](<https://example.com/span>)\(SpanManifestToken.span(marks: "bi", url: linkedURLManifest))"),
        .init(name: "code bold italic plain internal LF", marks: [.code, .bold, .italic], linkURL: nil, text: "A\nB", expectedMarkdown: "***`A\(ContinuationToken.soft)\nB`***\(SpanManifestToken.span(marks: "bci"))"),
        .init(name: "code bold italic plain terminal LF", marks: [.code, .bold, .italic], linkURL: nil, text: "A\n", expectedMarkdown: "***`A\(ContinuationToken.soft)`***\(SpanManifestToken.span(marks: "bci"))"),
        .init(name: "code bold italic linked internal LF", marks: [.code, .bold, .italic], linkURL: linkedURL, text: "A\nB", expectedMarkdown: "[***`A\(ContinuationToken.soft)\nB`***](<https://example.com/span>)\(SpanManifestToken.span(marks: "bci", url: linkedURLManifest))"),
        .init(name: "code bold italic linked terminal LF", marks: [.code, .bold, .italic], linkURL: linkedURL, text: "A\n", expectedMarkdown: "[***`A\(ContinuationToken.soft)`***](<https://example.com/span>)\(SpanManifestToken.span(marks: "bci", url: linkedURLManifest))")
    ]
}

struct ContinuationParityFixture: Sendable {
    let name: String
    let markdown: String
    let expectedText: String

    static let all: [ContinuationParityFixture] = [
        .init(name: "zero backslashes activates token", markdown: "A\(ContinuationToken.soft)\nB", expectedText: "A\nB"),
        .init(name: "one backslash keeps token literal", markdown: "A\\\(ContinuationToken.soft)\nB", expectedText: "A\(ContinuationToken.soft)\nB"),
        .init(name: "two backslashes activates token", markdown: "A" + String(repeating: "\\", count: 2) + ContinuationToken.soft + "\nB", expectedText: "A\\\nB"),
        .init(name: "three backslashes keeps token literal", markdown: "A" + String(repeating: "\\", count: 3) + ContinuationToken.soft + "\nB", expectedText: "A\\\(ContinuationToken.soft)\nB")
    ]
}

struct LiteralContinuationExportFixture: Sendable {
    let name: String
    let modelText: String
    let canonicalMarkdown: String

    static let all: [LiteralContinuationExportFixture] = [
        .init(name: "literal token", modelText: "A\(ContinuationToken.soft)", canonicalMarkdown: "A\\\(ContinuationToken.soft)"),
        .init(name: "literal token after one backslash", modelText: "A\\\(ContinuationToken.soft)", canonicalMarkdown: "A" + String(repeating: "\\", count: 3) + ContinuationToken.soft),
        .init(name: "hard break after literal backslash", modelText: "A\\\nB", canonicalMarkdown: "A" + String(repeating: "\\", count: 2) + ContinuationToken.soft + "\nB")
    ]
}

struct UnmarkedBoundaryFixture: Sendable {
    let name: String
    let markdown: String
    let leadingKind: BlockKind
    let followingKind: BlockKind

    private struct Leading {
        let name: String
        let markdown: String
        let kind: BlockKind
    }

    private struct Following {
        let name: String
        let markdown: String
        let kind: BlockKind
    }

    static let all: [UnmarkedBoundaryFixture] = {
        let leading = [
            Leading(name: "heading 1", markdown: "# first", kind: .heading1),
            Leading(name: "heading 2", markdown: "## first", kind: .heading2),
            Leading(name: "heading 3", markdown: "### first", kind: .heading3),
            Leading(name: "bullet", markdown: "- first", kind: .bullet),
            Leading(name: "ordered", markdown: "1. first", kind: .ordered),
            Leading(name: "task", markdown: "- [ ] first", kind: .task),
            Leading(name: "link", markdown: "[first](https://example.com/first)", kind: .link)
        ]
        let following = [
            Following(name: "bare paragraph", markdown: "正文", kind: .paragraph),
            Following(name: "heading 1", markdown: "# next", kind: .heading1),
            Following(name: "heading 2", markdown: "## next", kind: .heading2),
            Following(name: "heading 3", markdown: "### next", kind: .heading3),
            Following(name: "bullet", markdown: "- next", kind: .bullet),
            Following(name: "ordered", markdown: "1. next", kind: .ordered),
            Following(name: "task", markdown: "- [ ] next", kind: .task),
            Following(name: "quote", markdown: "> next", kind: .quote),
            Following(name: "code", markdown: "```swift\nlet value = 1\n```", kind: .code),
            Following(name: "divider", markdown: "---", kind: .divider),
            Following(name: "single line link", markdown: "[next](https://example.com/next)", kind: .link),
            Following(name: "multiline link", markdown: "[next\nlabel](https://example.com/next)", kind: .link),
            Following(name: "unsupported raw text", markdown: "| raw |", kind: .paragraph),
            Following(name: "blank then paragraph", markdown: "\n正文", kind: .paragraph)
        ]
        return leading.flatMap { leading in
            following.map { following in
                .init(
                    name: "\(leading.name) then \(following.name)",
                    markdown: "\(leading.markdown)\n\(following.markdown)",
                    leadingKind: leading.kind,
                    followingKind: following.kind
                )
            }
        }
    }()
}

struct MultilineProseFixture: Sendable {
    let name: String
    let document: BlockDocument
    let canonicalMarkdown: String

    private static let content = InlineContent.plain("a\nb  \nc\n")
    private static let linkURL = URL(string: "https://example.com/multiline")!

    private static func id(_ value: Int) -> BlockID {
        let string = String(format: "00000000-0000-0000-0000-%012d", value)
        return BlockID(UUID(uuidString: string)!)
    }

    static let all: [MultilineProseFixture] = [
        .init(
            name: "paragraph",
            document: .init(blocks: [.init(id: id(600), kind: .paragraph, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))"
        ),
        .init(
            name: "heading 1",
            document: .init(blocks: [.init(id: id(601), kind: .heading1, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "# a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))"
        ),
        .init(
            name: "heading 2",
            document: .init(blocks: [.init(id: id(602), kind: .heading2, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "## a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))"
        ),
        .init(
            name: "heading 3",
            document: .init(blocks: [.init(id: id(603), kind: .heading3, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "### a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))"
        ),
        .init(
            name: "bullet",
            document: .init(blocks: [.init(id: id(604), kind: .bullet, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "- a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))"
        ),
        .init(
            name: "ordered",
            document: .init(blocks: [.init(id: id(605), kind: .ordered, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "1. a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))"
        ),
        .init(
            name: "task",
            document: .init(blocks: [.init(id: id(606), kind: .task, inlineContent: content, taskState: .init(completedAt: .distantPast), indentLevel: 0)]),
            canonicalMarkdown: "- [x] a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))"
        ),
        .init(
            name: "quote",
            document: .init(blocks: [.init(id: id(607), kind: .quote, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "> a\(ContinuationToken.soft)\n> b\(ContinuationToken.hard)\n> c\(ContinuationToken.soft)\(SpanManifestToken.span(marks: "~"))"
        ),
        .init(
            name: "link",
            document: .init(blocks: [.init(id: id(608), kind: .link, inlineContent: .init(spans: [.init(text: "a\nb  \nc\n", linkURL: linkURL)]), taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "\(SpanManifestToken.blockLink)[a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)](<https://example.com/multiline>)\(SpanManifestToken.span(marks: "~", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS9tdWx0aWxpbmU"))"
        )
    ]
}

struct ProseContinuationWhitespaceFixture: Sendable {
    let name: String
    let kind: BlockKind
    let modelText: String
    let encodedContent: String

    private static let linkURL = URL(string: "https://example.com/whitespace")!

    static let all: [ProseContinuationWhitespaceFixture] = {
        let kinds: [(String, BlockKind)] = [
            ("paragraph", .paragraph),
            ("heading 1", .heading1),
            ("heading 2", .heading2),
            ("heading 3", .heading3),
            ("bullet", .bullet),
            ("ordered", .ordered),
            ("task", .task),
            ("quote", .quote),
            ("link", .link)
        ]
        let whitespaceCases: [(String, String, String)] = [
            ("empty first line", "\na", "\(ContinuationToken.soft)\na"),
            ("one ASCII space", "a \nb", "a \(ContinuationToken.soft)\nb"),
            ("two ASCII spaces hard break", "a  \nb", "a\(ContinuationToken.hard)\nb"),
            ("three ASCII spaces", "a   \nb", "a \(ContinuationToken.hard)\nb"),
            ("one tab", "a\t\nb", "a\t\(ContinuationToken.soft)\nb"),
            ("two tabs", "a\t\t\nb", "a\t\t\(ContinuationToken.soft)\nb"),
            ("mixed tab then hard break", "a \t  \nb", "a \t\(ContinuationToken.hard)\nb")
        ]
        return kinds.flatMap { kind in
            whitespaceCases.map { whitespace in
                .init(
                    name: "\(kind.0) \(whitespace.0)",
                    kind: kind.1,
                    modelText: whitespace.1,
                    encodedContent: whitespace.2
                )
            }
        }
    }()

    func document(id: BlockID) -> BlockDocument {
        let inlineContent: InlineContent
        if kind == .link {
            inlineContent = .init(spans: [.init(text: modelText, linkURL: Self.linkURL)])
        } else {
            inlineContent = .plain(modelText)
        }
        return .init(blocks: [
            .init(
                id: id,
                kind: kind,
                inlineContent: inlineContent,
                taskState: kind == .task ? .init(completedAt: nil) : nil,
                indentLevel: 0
            )
        ])
    }

    var canonicalMarkdown: String {
        let visible: String
        switch kind {
        case .paragraph:
            visible = encodedContent
        case .heading1:
            visible = "# \(encodedContent)"
        case .heading2:
            visible = "## \(encodedContent)"
        case .heading3:
            visible = "### \(encodedContent)"
        case .bullet:
            visible = "- \(encodedContent)"
        case .ordered:
            visible = "1. \(encodedContent)"
        case .task:
            visible = "- [ ] \(encodedContent)"
        case .quote:
            visible = encodedContent
                .components(separatedBy: "\n")
                .map { "> \($0)" }
                .joined(separator: "\n")
        case .link:
            return SpanManifestToken.blockLink +
                "[\(encodedContent)](<\(Self.linkURL.absoluteString)>)" +
                SpanManifestToken.span(marks: "~", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS93aGl0ZXNwYWNl")
        case .code, .divider:
            fatalError("Fixture only supports prose block kinds")
        }
        return visible + SpanManifestToken.span(marks: "~")
    }
}

struct BlockMarkdownFixture: Sendable {
    let name: String
    let markdown: String
    let canonicalMarkdown: String
    let document: BlockDocument
    let blockIDs: [BlockID]
    let checkedTaskCompletedAt: Date

    var ids: BlockIDSource { .fixed(blockIDs) }

    static let all: [BlockMarkdownFixture] = [
        fixture(
            name: "inline prose with Chinese soft break and inline link",
            markdown: "原始 **加粗**、*斜体*、`代码` 与 [链接](https://example.com/a)\n第二行",
            canonicalMarkdown: "原始 \(SpanManifestToken.span(marks: "~"))**加粗**\(SpanManifestToken.span(marks: "b"))、\(SpanManifestToken.span(marks: "~"))*斜体*\(SpanManifestToken.span(marks: "i"))、\(SpanManifestToken.span(marks: "~"))`代码`\(SpanManifestToken.span(marks: "c")) 与 \(SpanManifestToken.span(marks: "~"))[链接](<https://example.com/a>)\(SpanManifestToken.span(marks: "~", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS9h"))\(ContinuationToken.soft)\n第二行\(SpanManifestToken.span(marks: "~"))",
            blocks: [
                .init(
                    kind: .paragraph,
                    content: .init(spans: [
                        .init(text: "原始 "),
                        .init(text: "加粗", marks: [.bold]),
                        .init(text: "、"),
                        .init(text: "斜体", marks: [.italic]),
                        .init(text: "、"),
                        .init(text: "代码", marks: [.code]),
                        .init(text: " 与 "),
                        .init(text: "链接", linkURL: URL(string: "https://example.com/a")!),
                        .init(text: "\n第二行")
                    ]),
                    taskState: nil,
                    indent: 0,
                    codeInfoString: nil
                )
            ]
        ),
        fixture(
            name: "three heading levels",
            markdown: "# 一级\n\n## 二级\n\n### 三级",
            canonicalMarkdown: "# 一级\(SpanManifestToken.span(marks: "~"))\n\n## 二级\(SpanManifestToken.span(marks: "~"))\n\n### 三级\(SpanManifestToken.span(marks: "~"))",
            blocks: [
                .init(kind: .heading1, content: .plain("一级"), taskState: nil, indent: 0, codeInfoString: nil),
                .init(kind: .heading2, content: .plain("二级"), taskState: nil, indent: 0, codeInfoString: nil),
                .init(kind: .heading3, content: .plain("三级"), taskState: nil, indent: 0, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "nested bullet ordered and task blocks",
            markdown: "- 一级\n    1. 二级\n        - [ ] 未完成\n            - [x] 已完成",
            canonicalMarkdown: "- 一级\(SpanManifestToken.span(marks: "~"))\n    1. 二级\(SpanManifestToken.span(marks: "~"))\n        - [ ] 未完成\(SpanManifestToken.span(marks: "~"))\n            - [x] 已完成\(SpanManifestToken.span(marks: "~"))",
            blocks: [
                .init(kind: .bullet, content: .plain("一级"), taskState: nil, indent: 0, codeInfoString: nil),
                .init(kind: .ordered, content: .plain("二级"), taskState: nil, indent: 1, codeInfoString: nil),
                .init(kind: .task, content: .plain("未完成"), taskState: .init(completedAt: nil), indent: 2, codeInfoString: nil),
                .init(kind: .task, content: .plain("已完成"), taskState: .init(completedAt: completionTime), indent: 3, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "quote with soft break",
            markdown: "> 第一行\n> 第二行",
            canonicalMarkdown: "> 第一行\(ContinuationToken.soft)\n> 第二行\(SpanManifestToken.span(marks: "~"))",
            blocks: [
                .init(kind: .quote, content: .plain("第一行\n第二行"), taskState: nil, indent: 0, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "code fence with complete info string",
            markdown: "```swift linenums=1\nlet value = 1\nprint(value)\n```",
            canonicalMarkdown: "```swift linenums=1\nlet value = 1\nprint(value)\n```",
            blocks: [
                .init(kind: .code, content: .plain("let value = 1\nprint(value)"), taskState: nil, indent: 0, codeInfoString: "swift linenums=1")
            ]
        ),
        fixture(
            name: "divider",
            markdown: "---",
            canonicalMarkdown: "---",
            blocks: [
                .init(kind: .divider, content: .plain(""), taskState: nil, indent: 0, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "link block",
            markdown: "[规范](https://example.com/spec)",
            canonicalMarkdown: "\(SpanManifestToken.blockLink)[规范](<https://example.com/spec>)\(SpanManifestToken.span(marks: "~", url: "aHR0cHM6Ly9leGFtcGxlLmNvbS9zcGVj"))",
            blocks: [
                .init(kind: .link, content: .init(spans: [.init(text: "规范", linkURL: URL(string: "https://example.com/spec")!)]), taskState: nil, indent: 0, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "escaped markers remain literal",
            markdown: "\\*不是斜体\\* 与 \\[方括号\\] 和 \\`反引号\\`",
            canonicalMarkdown: "\\*不是斜体\\* 与 \\[方括号\\] 和 \\`反引号\\`\(SpanManifestToken.span(marks: "~"))",
            blocks: [
                .init(kind: .paragraph, content: .plain("*不是斜体* 与 [方括号] 和 `反引号`"), taskState: nil, indent: 0, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "long code delimiter run",
            markdown: "````swift\nlet fence = ```\n````",
            canonicalMarkdown: "````swift\nlet fence = ```\n````",
            blocks: [
                .init(kind: .code, content: .plain("let fence = ```"), taskState: nil, indent: 0, codeInfoString: "swift")
            ]
        )
    ]

    private static let completionTime = Date(timeIntervalSince1970: 1_786_320_400)

    private struct ExpectedBlock: Sendable {
        let kind: BlockKind
        let content: InlineContent
        let taskState: TaskBlockState?
        let indent: Int
        let codeInfoString: String?
    }

    private static func fixture(
        name: String,
        markdown: String,
        canonicalMarkdown: String,
        blocks: [ExpectedBlock]
    ) -> BlockMarkdownFixture {
        let blockIDs = (0..<blocks.count).map { offset in
            BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 10 + offset))!)
        }
        return BlockMarkdownFixture(
            name: name,
            markdown: markdown,
            canonicalMarkdown: canonicalMarkdown,
            document: .init(blocks: zip(blockIDs, blocks).map { id, block in
                .init(
                    id: id,
                    kind: block.kind,
                    inlineContent: block.content,
                    taskState: block.taskState,
                    indentLevel: block.indent,
                    codeInfoString: block.codeInfoString
                )
            }),
            blockIDs: blockIDs,
            checkedTaskCompletedAt: completionTime
        )
    }
}
