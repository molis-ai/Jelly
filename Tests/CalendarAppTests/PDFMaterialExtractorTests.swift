import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("PDFMaterialExtractorTests")
struct PDFMaterialExtractorTests {
    @Test func digitalPagesUseTextAndOnlyScannedPagesUseOCR() async throws {
        let loader = FixturePDFPageLoader(pages: [
            .init(number: 1, text: "第一页数字正文", renderedImageData: nil),
            .init(number: 2, text: nil, renderedImageData: Data([2])),
            .init(number: 3, text: "第三页数字正文", renderedImageData: nil)
        ])
        let ocr = RecordingPDFOCRRecognizer(results: [
            2: .success([.init(text: "扫描页文字", confidence: 0.96)])
        ])

        let batch = try await PDFMaterialExtractor(loader: loader, ocr: ocr)
            .extract(url: URL(fileURLWithPath: "/tmp/mixed.pdf"))

        #expect(batch.blocks.map(\.text) == ["第一页数字正文", "扫描页文字", "第三页数字正文"])
        #expect(batch.blocks.map(\.role) == [.body, .ocr, .body])
        #expect(batch.blocks.map(\.locator) == [
            .page(number: 1), .page(number: 2), .page(number: 3)
        ])
        #expect(ocr.requestedPageNumbers == [2])
        #expect(batch.coverage == .sufficient)
    }

    @Test func failedScannedPageKeepsDigitalPagesAsPartial() async throws {
        let loader = FixturePDFPageLoader(pages: [
            .init(number: 1, text: "可用正文", renderedImageData: nil),
            .init(number: 2, text: nil, renderedImageData: Data([2]))
        ])
        let ocr = RecordingPDFOCRRecognizer(results: [2: .failure(.unreadable)])

        let batch = try await PDFMaterialExtractor(loader: loader, ocr: ocr)
            .extract(url: URL(fileURLWithPath: "/tmp/partial.pdf"))

        #expect(batch.blocks.map(\.text) == ["可用正文"])
        #expect(batch.coverage == .partial(processed: 1, expected: 2, issues: [.ocrFailed]))
    }

    @Test func allUnreadablePagesAreInsufficient() async throws {
        let loader = FixturePDFPageLoader(pages: [
            .init(number: 1, text: nil, renderedImageData: nil)
        ])
        let batch = try await PDFMaterialExtractor(
            loader: loader,
            ocr: RecordingPDFOCRRecognizer(results: [:])
        ).extract(url: URL(fileURLWithPath: "/tmp/unreadable.pdf"))

        #expect(batch.blocks.isEmpty)
        #expect(batch.coverage == .insufficient(code: .unreadable))
    }
}

private struct FixturePDFPageLoader: PDFMaterialPageLoading {
    let pages: [PDFMaterialPage]
    func loadPages(from url: URL) throws -> [PDFMaterialPage] { pages }
}

private final class RecordingPDFOCRRecognizer: MaterialOCRRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [Int: Result<[MaterialOCRLine], MaterialOCRRecognitionError>]
    private var requested: [Int] = []

    init(results: [Int: Result<[MaterialOCRLine], MaterialOCRRecognitionError>]) {
        self.results = results
    }

    var requestedPageNumbers: [Int] { lock.withLock { requested } }

    func recognize(_ image: MaterialImageAsset) async throws -> [MaterialOCRLine] {
        lock.withLock { requested.append(image.index) }
        return try results[image.index, default: .failure(.unreadable)].get()
    }
}
