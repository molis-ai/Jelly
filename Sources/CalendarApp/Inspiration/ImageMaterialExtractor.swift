import CoreGraphics
import Foundation
import ImageIO
import Vision
import WorkspaceDomain

struct MaterialImageAsset: Equatable, Sendable {
    let index: Int
    let data: Data
}

struct MaterialOCRLine: Equatable, Sendable {
    let text: String
    let confidence: Double
}

enum MaterialOCRRecognitionError: Error, Equatable {
    case unreadable
    case tooLarge
}

protocol MaterialOCRRecognizing: Sendable {
    func recognize(_ image: MaterialImageAsset) async throws -> [MaterialOCRLine]
}

struct VisionMaterialOCRRecognizer: MaterialOCRRecognizing, Sendable {
    private let maximumPixels: Int

    init(maximumPixels: Int = 40_000_000) {
        self.maximumPixels = maximumPixels
    }

    func recognize(_ image: MaterialImageAsset) async throws -> [MaterialOCRLine] {
        let data = image.data
        let maximumPixels = maximumPixels
        return try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw MaterialOCRRecognitionError.unreadable
            }
            let (pixels, overflow) = cgImage.width.multipliedReportingOverflow(by: cgImage.height)
            guard !overflow, pixels <= maximumPixels else {
                throw MaterialOCRRecognitionError.tooLarge
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                throw MaterialOCRRecognitionError.unreadable
            }
            return (request.results ?? [])
                .sorted { lhs, rhs in
                    if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > 0.01 {
                        return lhs.boundingBox.maxY > rhs.boundingBox.maxY
                    }
                    return lhs.boundingBox.minX < rhs.boundingBox.minX
                }
                .compactMap { observation -> MaterialOCRLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard MaterialTranscriptSemantics.hasSemanticContent(text) else { return nil }
                    return MaterialOCRLine(text: text, confidence: Double(candidate.confidence))
                }
        }.value
    }
}

struct ImageMaterialExtractor: Sendable {
    let recognizer: any MaterialOCRRecognizing
    private let maximumImages: Int
    private let maximumCharacters: Int

    init(
        recognizer: any MaterialOCRRecognizing = VisionMaterialOCRRecognizer(),
        maximumImages: Int = 100,
        maximumCharacters: Int = MaterialDigestContentLimits.maximumMaterialCharacters
    ) {
        self.recognizer = recognizer
        self.maximumImages = maximumImages
        self.maximumCharacters = maximumCharacters
    }

    func extract(_ images: [MaterialImageAsset]) async throws -> MaterialBlockBatch {
        guard !images.isEmpty else {
            return batch(blocks: [], coverage: .insufficient(code: .empty))
        }
        guard images.count <= maximumImages else {
            throw MaterialDigestPipelineError.contextTooLong
        }
        var blocks: [MaterialBlock] = []
        var fingerprints: Set<String> = []
        var processed = 0
        var issues: [MaterialCoverageIssue] = []
        var totalCharacters = 0

        for image in images.sorted(by: { $0.index < $1.index }) {
            try Task.checkCancellation()
            do {
                let lines = try await recognizer.recognize(image)
                let semanticLines = lines.filter {
                    MaterialTranscriptSemantics.hasSemanticContent($0.text)
                }
                guard !semanticLines.isEmpty else {
                    if !issues.contains(.ocrFailed) { issues.append(.ocrFailed) }
                    continue
                }
                processed += 1
                for line in semanticLines {
                    let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fingerprint = Self.fingerprint(text)
                    guard !fingerprint.isEmpty, fingerprints.insert(fingerprint).inserted else { continue }
                    guard totalCharacters + text.count <= maximumCharacters else {
                        if !issues.contains(.truncatedByLimit) { issues.append(.truncatedByLimit) }
                        continue
                    }
                    totalCharacters += text.count
                    blocks.append(MaterialBlock(
                        id: MaterialBlockID(),
                        role: .ocr,
                        text: text,
                        locator: .image(index: image.index),
                        confidence: MaterialConfidence(
                            basisPoints: Int((min(1, max(0, line.confidence)) * 10_000).rounded())
                        )
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !issues.contains(.ocrFailed) { issues.append(.ocrFailed) }
            }
        }

        let coverage: MaterialCoverage
        if blocks.isEmpty {
            coverage = .insufficient(code: .unreadable)
        } else if processed == images.count, issues.isEmpty {
            coverage = .sufficient
        } else {
            coverage = .partial(processed: processed, expected: images.count, issues: issues)
        }
        return batch(blocks: blocks, coverage: coverage)
    }

    private func batch(blocks: [MaterialBlock], coverage: MaterialCoverage) -> MaterialBlockBatch {
        MaterialBlockBatch(
            blocks: blocks,
            coverage: coverage,
            provenance: MaterialAcquisitionProvenance(
                adapterIdentifier: "vision-ocr",
                adapterVersion: "1",
                acquiredAt: Date()
            )
        )
    }

    private static func fingerprint(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
