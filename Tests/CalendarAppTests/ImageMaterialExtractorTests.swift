import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("ImageMaterialExtractorTests")
struct ImageMaterialExtractorTests {
    @Test func orderedImagesProduceDeduplicatedOCRAndPartialCoverage() async throws {
        let recognizer = FixtureOCRRecognizer(results: [
            1: .success([.init(text: "第一张文字", confidence: 0.98)]),
            2: .failure(.unreadable),
            3: .success([
                .init(text: "第一张文字", confidence: 0.97),
                .init(text: "第三张补充", confidence: 0.95)
            ])
        ])
        let images = (1...3).map { MaterialImageAsset(index: $0, data: Data([UInt8($0)])) }

        let batch = try await ImageMaterialExtractor(recognizer: recognizer).extract(images)

        #expect(batch.blocks.map(\.text) == ["第一张文字", "第三张补充"])
        #expect(batch.blocks.map(\.locator) == [.image(index: 1), .image(index: 3)])
        #expect(batch.blocks.map { $0.confidence?.basisPoints } == [9800, 9500])
        #expect(batch.coverage == .partial(processed: 2, expected: 3, issues: [.ocrFailed]))
    }

    @Test func allUnreadableImagesAreInsufficient() async throws {
        let recognizer = FixtureOCRRecognizer(results: [1: .failure(.unreadable)])
        let batch = try await ImageMaterialExtractor(recognizer: recognizer).extract([
            MaterialImageAsset(index: 1, data: Data([1]))
        ])

        #expect(batch.blocks.isEmpty)
        #expect(batch.coverage == .insufficient(code: .unreadable))
    }

    @Test func imageLimitFailsBeforeVisionWork() async {
        let recognizer = FixtureOCRRecognizer(results: [:])
        let extractor = ImageMaterialExtractor(recognizer: recognizer, maximumImages: 1)

        await #expect(throws: MaterialDigestPipelineError.contextTooLong) {
            _ = try await extractor.extract([
                MaterialImageAsset(index: 1, data: Data([1])),
                MaterialImageAsset(index: 2, data: Data([2]))
            ])
        }
        #expect(recognizer.requestedIndices.isEmpty)
    }
}

private final class FixtureOCRRecognizer: MaterialOCRRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [Int: Result<[MaterialOCRLine], MaterialOCRRecognitionError>]
    private var indices: [Int] = []

    init(results: [Int: Result<[MaterialOCRLine], MaterialOCRRecognitionError>]) {
        self.results = results
    }

    var requestedIndices: [Int] { lock.withLock { indices } }

    func recognize(_ image: MaterialImageAsset) async throws -> [MaterialOCRLine] {
        lock.withLock { indices.append(image.index) }
        return try results[image.index, default: .failure(.unreadable)].get()
    }
}
