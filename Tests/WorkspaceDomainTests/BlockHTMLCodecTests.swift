import Foundation
import Testing
@testable import WorkspaceDomain

@Suite("BlockHTMLCodecTests")
struct BlockHTMLCodecTests {
    @Test func commonHTMLImportsSupportedStructureWithoutFlattening() throws {
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <!doctype html>
        <html><body>
        <h1>背景</h1>
        <p><strong>粗体</strong>、<em>斜体</em>、<code>行内代码</code>和<a href="https://example.com">链接</a></p>
        <ul>
          <li>项目</li>
          <li><input type="checkbox" checked>完成事项</li>
        </ul>
        <blockquote>引用<br>第二行</blockquote>
        <pre><code class="language-swift">let value = 1</code></pre>
        <hr>
        </body></html>
        """

        let result = try BlockHTMLCodec.importHTML(
            html,
            checkedTaskCompletedAt: completedAt
        )

        #expect(result.document.blocks.map(\.kind) == [
            .heading1, .paragraph, .bullet, .task, .quote, .code, .divider
        ])
        #expect(result.document.blocks[0].inlineContent.plainText == "背景")
        #expect(result.document.blocks[1].inlineContent.spans == [
            .init(text: "粗体", marks: [.bold]),
            .init(text: "、"),
            .init(text: "斜体", marks: [.italic]),
            .init(text: "、"),
            .init(text: "行内代码", marks: [.code]),
            .init(text: "和"),
            .init(text: "链接", linkURL: URL(string: "https://example.com")!)
        ])
        #expect(result.document.blocks[2].inlineContent.plainText == "项目")
        #expect(result.document.blocks[3].inlineContent.plainText == "完成事项")
        #expect(result.document.blocks[3].taskState?.completedAt == completedAt)
        #expect(result.document.blocks[4].inlineContent.plainText == "引用\n第二行")
        #expect(result.document.blocks[5].inlineContent.plainText == "let value = 1")
        #expect(result.document.blocks[5].codeInfoString == "swift")
        #expect(result.diagnostics.isEmpty)
    }

    @Test func exportedHTMLRoundTripsEverySupportedJellyStructure() throws {
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let link = URL(string: "https://example.com/spec")!
        let blocks: [DocumentBlock] = [
            .init(id: BlockID(), kind: .heading1, inlineContent: .plain("一级"), taskState: nil, indentLevel: 0),
            .init(id: BlockID(), kind: .heading2, inlineContent: .plain("二级"), taskState: nil, indentLevel: 0),
            .init(id: BlockID(), kind: .heading3, inlineContent: .plain("三级"), taskState: nil, indentLevel: 0),
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .init(spans: [
                    .init(text: "粗斜", marks: [.bold, .italic]),
                    .init(text: "链接", marks: [.code], linkURL: link)
                ]),
                taskState: nil,
                indentLevel: 0
            ),
            .init(id: BlockID(), kind: .bullet, inlineContent: .plain("项目"), taskState: nil, indentLevel: 0),
            .init(id: BlockID(), kind: .ordered, inlineContent: .plain("子项"), taskState: nil, indentLevel: 1),
            .init(id: BlockID(), kind: .task, inlineContent: .plain("完成"), taskState: .init(completedAt: completedAt), indentLevel: 2),
            .init(id: BlockID(), kind: .quote, inlineContent: .plain("引用\n续行"), taskState: nil, indentLevel: 0),
            .init(id: BlockID(), kind: .code, inlineContent: .plain("let value = 1"), taskState: nil, indentLevel: 0, codeInfoString: "swift"),
            .init(id: BlockID(), kind: .divider, inlineContent: .plain(""), taskState: nil, indentLevel: 0),
            .init(
                id: BlockID(),
                kind: .link,
                inlineContent: .init(spans: [.init(text: "规范", linkURL: link)]),
                taskState: nil,
                indentLevel: 0
            )
        ]
        let original = BlockDocument(blocks: blocks)

        let html = try BlockHTMLCodec.exportHTML(original, title: "验收笔记")
        let reimported = try BlockHTMLCodec.importHTML(
            html,
            checkedTaskCompletedAt: completedAt
        ).document

        #expect(reimported.blocks.map(\.kind) == blocks.map(\.kind))
        #expect(reimported.blocks.map(\.inlineContent) == blocks.map(\.inlineContent))
        #expect(reimported.blocks.map(\.indentLevel) == blocks.map(\.indentLevel))
        #expect(reimported.blocks.map(\.taskState) == blocks.map(\.taskState))
        #expect(reimported.blocks.map(\.codeInfoString) == blocks.map(\.codeInfoString))
        #expect(html.contains("<title>验收笔记</title>"))
    }

    @Test func unsupportedImagesAndTablesProduceVisibleDiagnostics() throws {
        let result = try BlockHTMLCodec.importHTML(
            "<p>保留</p><img src=\"x.png\" alt=\"示意图\"><table><tr><td>数据</td></tr></table>",
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks.map(\.inlineContent.plainText) == ["保留", "示意图", "数据"])
        #expect(result.diagnostics.map(\.message) == [
            "图片无法原样导入，已保留替代文字",
            "表格结构暂不支持，已按正文保留"
        ])
    }

    @Test func jellyTaskCompletionAttributeRoundTripsWithoutExecutingMarkup() throws {
        let source = BlockDocument(blocks: [
            try .task(text: "给物业打电话", completionDescription: #"拿到<script>alert(1)</script>时间"#)
        ])
        let html = try BlockHTMLCodec.exportHTML(source, title: "完成说明")
        #expect(html.contains("data-jelly-completion-description="))
        #expect(html.contains("data-jelly-kind=\"task\""))
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("<script>alert(1)</script>"))

        let restored = try BlockHTMLCodec.importHTML(html, checkedTaskCompletedAt: .distantPast)
        #expect(restored.document.blocks.map(\.kind) == [.task])
        #expect(restored.document.blocks[0].inlineContent.plainText == "给物业打电话")
        #expect(restored.document.blocks[0].taskState?.completionDescription == #"拿到<script>alert(1)</script>时间"#)

        let external = try BlockHTMLCodec.importHTML(
            #"<ul><li data-jelly-kind="task"><input type="checkbox" disabled>外部任务</li></ul>"#,
            checkedTaskCompletedAt: .distantPast
        )
        #expect(external.document.blocks[0].taskState?.completionDescription == nil)

        let malicious = try BlockHTMLCodec.importHTML(
            #"<ul><li data-jelly-kind="task" data-jelly-completion-description="&lt;img src=x onerror=alert(1)&gt;原字符串"><input type="checkbox" disabled>恶意属性</li></ul>"#,
            checkedTaskCompletedAt: .distantPast
        )
        #expect(malicious.document.blocks[0].inlineContent.plainText == "恶意属性")
        #expect(malicious.document.blocks[0].taskState?.completionDescription == "<img src=x onerror=alert(1)>原字符串")
        #expect(malicious.diagnostics.isEmpty)
    }
}
