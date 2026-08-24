import AppKit
import Foundation
import PDFKit
import WorkspaceDomain

struct PDFMaterialPage: Equatable, Sendable {
    let number: Int
    let text: String?
    let renderedImageData: Data?
}

protocol PDFMaterialPageLoading: Sendable {
    func loadPages(from url: URL) throws -> [PDFMaterialPage]
}

struct PDFKitMaterialPageLoader: PDFMaterialPageLoading, Sendable {
    private let maximumPages: Int
    private let maximumRasterDimension: CGFloat

    init(maximumPages: Int = 1_000, maximumRasterDimension: CGFloat = 2_200) {
        self.maximumPages = maximumPages
        self.maximumRasterDimension = maximumRasterDimension
    }

    func loadPages(from url: URL) throws -> [PDFMaterialPage] {
        guard url.isFileURL, let document = PDFDocument(url: url), !document.isLocked else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        guard document.pageCount <= maximumPages else {
            throw MaterialDigestPipelineError.contextTooLong
        }
        return (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                return PDFMaterialPage(number: index + 1, text: nil, renderedImageData: nil)
            }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, MaterialTranscriptSemantics.hasSemanticContent(text) {
                return PDFMaterialPage(number: index + 1, text: text, renderedImageData: nil)
            }
            return PDFMaterialPage(
                number: index + 1,
                text: nil,
                renderedImageData: Self.renderedPNG(
                    page,
                    maximumDimension: maximumRasterDimension
                )
            )
        }
    }

    private static func renderedPNG(_ page: PDFPage, maximumDimension: CGFloat) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(3, maximumDimension / max(bounds.width, bounds.height))
        let size = NSSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff)
        else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}

struct PDFMaterialExtractor: Sendable {
    let loader: any PDFMaterialPageLoading
    let ocr: any MaterialOCRRecognizing
    private let maximumPages: Int
    private let maximumCharacters: Int

    init(
        loader: any PDFMaterialPageLoading = PDFKitMaterialPageLoader(),
        ocr: any MaterialOCRRecognizing = VisionMaterialOCRRecognizer(),
        maximumPages: Int = 1_000,
        maximumCharacters: Int = MaterialDigestContentLimits.maximumMaterialCharacters
    ) {
        self.loader = loader
        self.ocr = ocr
        self.maximumPages = maximumPages
        self.maximumCharacters = maximumCharacters
    }

    func extract(url: URL) async throws -> MaterialBlockBatch {
        let pages = try loader.loadPages(from: url).sorted { $0.number < $1.number }
        guard !pages.isEmpty else {
            return batch(blocks: [], coverage: .insufficient(code: .empty))
        }
        guard pages.count <= maximumPages else {
            throw MaterialDigestPipelineError.contextTooLong
        }
        var blocks: [MaterialBlock] = []
        var processed = 0
        var issues: [MaterialCoverageIssue] = []
        var totalCharacters = 0

        for page in pages {
            try Task.checkCancellation()
            if let text = page.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               MaterialTranscriptSemantics.hasSemanticContent(text) {
                guard totalCharacters + text.count <= maximumCharacters else {
                    throw MaterialDigestPipelineError.contextTooLong
                }
                totalCharacters += text.count
                processed += 1
                blocks.append(MaterialBlock(
                    id: MaterialBlockID(),
                    role: .body,
                    text: text,
                    locator: .page(number: page.number),
                    confidence: nil
                ))
                continue
            }
            guard let data = page.renderedImageData else {
                if !issues.contains(.ocrFailed) { issues.append(.ocrFailed) }
                continue
            }
            do {
                let lines = try await ocr.recognize(
                    MaterialImageAsset(index: page.number, data: data)
                )
                let unique = Self.uniqueSemanticLines(lines)
                let text = unique.map(\.text).joined(separator: "\n")
                guard MaterialTranscriptSemantics.hasSemanticContent(text) else {
                    if !issues.contains(.ocrFailed) { issues.append(.ocrFailed) }
                    continue
                }
                guard totalCharacters + text.count <= maximumCharacters else {
                    throw MaterialDigestPipelineError.contextTooLong
                }
                totalCharacters += text.count
                processed += 1
                let confidence = unique.isEmpty
                    ? nil
                    : unique.map(\.confidence).reduce(0, +) / Double(unique.count)
                blocks.append(MaterialBlock(
                    id: MaterialBlockID(),
                    role: .ocr,
                    text: text,
                    locator: .page(number: page.number),
                    confidence: confidence.map {
                        MaterialConfidence(
                            basisPoints: Int((min(1, max(0, $0)) * 10_000).rounded())
                        )
                    }
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MaterialDigestPipelineError {
                throw error
            } catch {
                if !issues.contains(.ocrFailed) { issues.append(.ocrFailed) }
            }
        }

        let coverage: MaterialCoverage
        if blocks.isEmpty {
            coverage = .insufficient(code: .unreadable)
        } else if processed == pages.count, issues.isEmpty {
            coverage = .sufficient
        } else {
            coverage = .partial(processed: processed, expected: pages.count, issues: issues)
        }
        return batch(blocks: blocks, coverage: coverage)
    }

    private func batch(blocks: [MaterialBlock], coverage: MaterialCoverage) -> MaterialBlockBatch {
        MaterialBlockBatch(
            blocks: blocks,
            coverage: coverage,
            provenance: MaterialAcquisitionProvenance(
                adapterIdentifier: "pdfkit",
                adapterVersion: "1",
                acquiredAt: Date()
            )
        )
    }

    private static func uniqueSemanticLines(_ lines: [MaterialOCRLine]) -> [MaterialOCRLine] {
        var seen: Set<String> = []
        return lines.filter { line in
            let fingerprint = MaterialDigestEvidence.foldedText(line.text)
            return !fingerprint.isEmpty && seen.insert(fingerprint).inserted
        }
    }
}
