import Foundation
import Testing
import UniformTypeIdentifiers
import WorkspaceDomain
@testable import CalendarApp

@Suite("TextMaterialExtractorTests")
struct TextMaterialExtractorTests {
    @Test func directTextBecomesOrderedBodyParagraphs() async throws {
        let batch = try await TextMaterialExtractor().extract(
            .direct(text: "第一段\r\n\r\n第二段\n仍在第二段")
        )

        #expect(batch.blocks.map(\.text) == ["第一段", "第二段\n仍在第二段"])
        #expect(batch.blocks.map(\.role) == [.body, .body])
        #expect(batch.blocks.map(\.locator) == [
            .paragraph(index: 1),
            .paragraph(index: 2)
        ])
        #expect(batch.coverage == .sufficient)
    }

    @Test func nulBinaryAndWhitespaceAreInsufficient() async throws {
        let binary = try await TextMaterialExtractor().extract(.direct(text: " \u{0000} "))
        let whitespace = try await TextMaterialExtractor().extract(.direct(text: " \n\n "))

        #expect(binary.blocks.isEmpty)
        #expect(binary.coverage == .insufficient(code: .empty))
        #expect(whitespace.blocks.isEmpty)
        #expect(whitespace.coverage == .insufficient(code: .empty))
    }

    @Test func utf16BOMFileAndMarkdownRemainVerbatimInsideParagraphs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-text-extractor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("材料.md")
        var data = Data([0xff, 0xfe])
        data.append(try #require("# 标题\n\n- 要点".data(using: .utf16LittleEndian)))
        try data.write(to: url)

        let batch = try await TextMaterialExtractor().extract(
            .file(url: url, utiIdentifier: UTType.plainText.identifier)
        )

        #expect(batch.blocks.map(\.text) == ["# 标题", "- 要点"])
        #expect(batch.coverage == .sufficient)
    }

    @Test func characterLimitFailsBeforeCreatingAPartialSummaryCandidate() async {
        let extractor = TextMaterialExtractor(maximumCharacters: 4)

        await #expect(throws: MaterialDigestPipelineError.contextTooLong) {
            _ = try await extractor.extract(.direct(text: "12345"))
        }
    }
}
