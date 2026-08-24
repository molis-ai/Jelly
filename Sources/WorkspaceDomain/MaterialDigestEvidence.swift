import Foundation

public enum MaterialDigestEvidence {
    public static let nearbyWindowSeconds: Double = 2.0

    public static func hasNonMetadataEvidence(
        _ claim: DigestClaim,
        blocks: [MaterialBlock]
    ) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        return claim.evidenceBlockIDs.contains { id in
            guard let block = byID[id] else { return false }
            return block.role != .metadata
        }
    }

    public static func transcriptEnd(_ transcript: TimestampedTranscript) -> Double {
        transcript.segments.map(\.endSeconds).max() ?? 0
    }

    public static func foldedText(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    public static func nearbyTranscriptText(
        _ transcript: TimestampedTranscript,
        at startSeconds: Double
    ) -> String {
        transcript.segments
            .filter {
                $0.endSeconds >= startSeconds - nearbyWindowSeconds
                    && $0.startSeconds <= startSeconds + nearbyWindowSeconds
            }
            .map(\.text)
            .joined()
    }

    public static func textAppearsNearby(
        _ text: String,
        at startSeconds: Double,
        in transcript: TimestampedTranscript
    ) -> Bool {
        let needle = foldedText(text)
        guard !needle.isEmpty else { return false }
        return foldedText(nearbyTranscriptText(transcript, at: startSeconds)).contains(needle)
    }

    public static func speakerAppearsNearby(
        _ speaker: String,
        at startSeconds: Double,
        in transcript: TimestampedTranscript
    ) -> Bool {
        textAppearsNearby(speaker, at: startSeconds, in: transcript)
    }

    public static func validateNewSummary(
        _ summary: InspirationSummary,
        against snapshot: MaterialSnapshot
    ) throws {
        let blocks = snapshot.blocks
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let blockIndexByID = Dictionary(
            uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) }
        )
        guard byID.count == blocks.count else {
            throw MaterialDigestEvidenceError.invalidSummary
        }

        try validateClaim(summary.thesisClaim, blocks: blocks, byID: byID)
        guard MaterialDigestContentLimits.takeawayCountRange.contains(summary.takeawayClaims.count) else {
            throw MaterialDigestEvidenceError.invalidSummary
        }
        for claim in summary.takeawayClaims {
            try validateClaim(claim, blocks: blocks, byID: byID)
        }
        guard summary.chapters.count <= MaterialDigestContentLimits.maximumChapters,
              summary.quotes.count <= MaterialDigestContentLimits.maximumQuotes,
              summary.droppedClaims.count <= MaterialDigestContentLimits.maximumDroppedItems
        else {
            throw MaterialDigestEvidenceError.invalidSummary
        }
        var previousChapterIndex = -1
        for chapter in summary.chapters {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  title.count <= MaterialDigestContentLimits.maximumChapterTitleCharacters,
                  (1...MaterialDigestContentLimits.maximumChapterPoints).contains(chapter.pointClaims.count)
            else {
                throw MaterialDigestEvidenceError.invalidSummary
            }
            guard let anchor = chapter.anchorBlockID,
                  let anchorBlock = byID[anchor],
                  anchorBlock.role != .metadata,
                  let anchorIndex = blockIndexByID[anchor],
                  anchorIndex >= previousChapterIndex
            else { throw MaterialDigestEvidenceError.invalidSummary }
            previousChapterIndex = anchorIndex
            for point in chapter.pointClaims {
                try validateClaim(point, blocks: blocks, byID: byID)
            }
        }
        for quote in summary.quotes {
            try validateQuote(quote, byID: byID)
        }
        for claim in summary.droppedClaims {
            try validateClaim(claim, blocks: blocks, byID: byID)
        }
    }

    public static func textAppearsInBlock(_ text: String, _ block: MaterialBlock) -> Bool {
        let needle = foldedText(text)
        guard !needle.isEmpty else { return false }
        return foldedText(block.text).contains(needle)
    }

    private static func validateClaim(
        _ claim: DigestClaim,
        blocks: [MaterialBlock],
        byID: [MaterialBlockID: MaterialBlock]
    ) throws {
        let text = claim.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !claim.evidenceBlockIDs.isEmpty,
              claim.evidenceBlockIDs.allSatisfy({ byID[$0] != nil }),
              hasNonMetadataEvidence(claim, blocks: blocks)
        else {
            throw MaterialDigestEvidenceError.invalidSummary
        }
    }

    private static func validateQuote(
        _ quote: DigestQuote,
        byID: [MaterialBlockID: MaterialBlock]
    ) throws {
        let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let evidenceID = quote.evidenceBlockID,
              let block = byID[evidenceID],
              textAppearsInBlock(text, block)
        else {
            throw MaterialDigestEvidenceError.invalidSummary
        }
        if let speaker = quote.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
           !speaker.isEmpty {
            guard textAppearsInBlock(speaker, block) else {
                throw MaterialDigestEvidenceError.invalidSummary
            }
        }
    }

    public static func sanitizedQuote(
        _ quote: DigestQuote,
        transcript: TimestampedTranscript,
        maximumSourceTime: Double
    ) -> DigestQuote? {
        let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let speaker = quote.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedSpeaker: String?
        if let speaker, !speaker.isEmpty, speakerAppearsNearby(speaker, at: quote.startSeconds, in: transcript) {
            supportedSpeaker = speaker
        } else {
            supportedSpeaker = nil
        }
        let kept = DigestQuote(
            speaker: supportedSpeaker,
            startSeconds: quote.startSeconds,
            text: text
        )
        if quote.startSeconds.isFinite,
           quote.startSeconds >= 0,
           quote.startSeconds <= maximumSourceTime,
           !textAppearsNearby(text, at: quote.startSeconds, in: transcript) {
            return nil
        }
        return kept
    }
}

public enum MaterialDigestEvidenceError: Error, Equatable, Sendable {
    case invalidSummary
}
