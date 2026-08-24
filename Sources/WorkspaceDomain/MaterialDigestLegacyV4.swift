import Foundation

public struct LegacyDigestChapterV4: Codable, Equatable, Sendable {
    public var startSeconds: Double
    public var title: String
    public var points: [String]

    public init(startSeconds: Double, title: String, points: [String]) {
        self.startSeconds = startSeconds
        self.title = title
        self.points = points
    }
}

public struct LegacyDigestQuoteV4: Codable, Equatable, Sendable {
    public var speaker: String?
    public var startSeconds: Double
    public var text: String

    public init(speaker: String?, startSeconds: Double, text: String) {
        self.speaker = speaker
        self.startSeconds = startSeconds
        self.text = text
    }
}

public struct LegacyInspirationSummaryV4: Codable, Equatable, Sendable {
    public var thesis: String
    public var takeaways: [String]
    public var chapters: [LegacyDigestChapterV4]
    public var quotes: [LegacyDigestQuoteV4]
    public var dropped: [String]

    public init(
        thesis: String,
        takeaways: [String],
        chapters: [LegacyDigestChapterV4],
        quotes: [LegacyDigestQuoteV4],
        dropped: [String]
    ) {
        self.thesis = thesis
        self.takeaways = takeaways
        self.chapters = chapters
        self.quotes = quotes
        self.dropped = dropped
    }
}

public struct LegacyMaterialDigestResultV4: Codable, Equatable, Sendable {
    public var transcript: TimestampedTranscript
    public var summary: LegacyInspirationSummaryV4
    public var provenance: DigestProvenance
    public var completedAt: Date

    public init(
        transcript: TimestampedTranscript,
        summary: LegacyInspirationSummaryV4,
        provenance: DigestProvenance,
        completedAt: Date
    ) {
        self.transcript = transcript
        self.summary = summary
        self.provenance = provenance
        self.completedAt = completedAt
    }
}

public struct LegacyMaterialDigestV4: Codable, Equatable, Sendable {
    public let id: MaterialDigestID
    public let inspirationID: InspirationID
    public let sourceChecksum: String
    public var currentRun: MaterialDigestRun?
    public var result: LegacyMaterialDigestResultV4?
    public var lastFailure: MaterialDigestFailure?
    public var noteWrite: MaterialDigestNoteWrite?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: MaterialDigestID,
        inspirationID: InspirationID,
        sourceChecksum: String,
        currentRun: MaterialDigestRun?,
        result: LegacyMaterialDigestResultV4?,
        lastFailure: MaterialDigestFailure?,
        noteWrite: MaterialDigestNoteWrite?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.inspirationID = inspirationID
        self.sourceChecksum = sourceChecksum
        self.currentRun = currentRun
        self.result = result
        self.lastFailure = lastFailure
        self.noteWrite = noteWrite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func migrated() throws -> MaterialDigest {
        let snapshot: MaterialSnapshot?
        let migratedResult: MaterialDigestResult?
        if let result {
            let blocks = result.transcript.segments.enumerated().map { index, segment in
                MaterialBlock(
                    id: MaterialBlockID(Self.stableBlockID(digestID: id, index: index)),
                    role: .transcript,
                    text: segment.text,
                    locator: .timestamp(
                        startSeconds: segment.startSeconds,
                        endSeconds: segment.endSeconds
                    ),
                    confidence: nil
                )
            }
            let draft = MaterialSnapshot(
                sourceChecksum: sourceChecksum,
                contentFingerprint: "pending",
                blocks: blocks,
                coverage: blocks.isEmpty ? .insufficient(code: .empty) : .sufficient,
                provenance: MaterialAcquisitionProvenance(
                    adapterIdentifier: "legacy-v4",
                    adapterVersion: "1",
                    acquiredAt: result.completedAt
                ),
                createdAt: createdAt
            )
            let fingerprint = try WorkspaceChecksum.materialSnapshotContentFingerprint(draft)
            let prepared = MaterialSnapshot(
                sourceChecksum: draft.sourceChecksum,
                contentFingerprint: fingerprint,
                blocks: draft.blocks,
                coverage: draft.coverage,
                provenance: draft.provenance,
                createdAt: draft.createdAt
            )
            snapshot = prepared
            migratedResult = MaterialDigestResult(
                summary: result.summary.migrated(against: prepared.blocks),
                provenance: result.provenance,
                completedAt: result.completedAt,
                contentFingerprint: fingerprint
            )
        } else {
            snapshot = nil
            migratedResult = nil
        }
        let migratedNoteWrite: MaterialDigestNoteWrite?
        if let noteWrite, let migratedResult {
            migratedNoteWrite = MaterialDigestNoteWrite(
                noteID: noteWrite.noteID,
                resultFingerprint: try WorkspaceChecksum.materialDigestResultFingerprint(migratedResult),
                blockIDs: noteWrite.blockIDs,
                writtenAt: noteWrite.writtenAt
            )
        } else {
            migratedNoteWrite = noteWrite
        }
        return MaterialDigest(
            id: id,
            inspirationID: inspirationID,
            sourceChecksum: sourceChecksum,
            currentRun: currentRun,
            result: migratedResult,
            lastFailure: lastFailure,
            noteWrite: migratedNoteWrite,
            preparedSnapshot: snapshot,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func stableBlockID(digestID: MaterialDigestID, index: Int) -> UUID {
        let digest = WorkspaceChecksum.sha256Hex(
            "material-digest-v4-block-v1|\(digestID.rawValue.uuidString.lowercased())|\(index)"
        )
        let compact = String(digest.prefix(32))
        let first = String(compact.prefix(8))
        let second = String(compact.dropFirst(8).prefix(4))
        let third = String(compact.dropFirst(12).prefix(4))
        let fourth = String(compact.dropFirst(16).prefix(4))
        let fifth = String(compact.dropFirst(20).prefix(12))
        let uuidString = "\(first)-\(second)-\(third)-\(fourth)-\(fifth)"
        return UUID(uuidString: uuidString)!
    }
}

extension LegacyInspirationSummaryV4 {
    func migrated(against blocks: [MaterialBlock]) -> InspirationSummary {
        InspirationSummary(
            thesis: DigestClaim(text: thesis, evidenceBlockIDs: []),
            takeaways: takeaways.map { DigestClaim(text: $0, evidenceBlockIDs: []) },
            chapters: chapters.map { chapter in
                DigestChapter(
                    title: chapter.title,
                    anchorBlockID: Self.blockID(at: chapter.startSeconds, in: blocks),
                    points: chapter.points.map { DigestClaim(text: $0, evidenceBlockIDs: []) },
                    startSeconds: chapter.startSeconds
                )
            },
            quotes: quotes.map { quote in
                DigestQuote(
                    speaker: quote.speaker,
                    startSeconds: quote.startSeconds,
                    text: quote.text,
                    evidenceBlockID: Self.blockID(at: quote.startSeconds, in: blocks)
                )
            },
            dropped: dropped.map { DigestClaim(text: $0, evidenceBlockIDs: []) }
        )
    }

    private static func blockID(at startSeconds: Double, in blocks: [MaterialBlock]) -> MaterialBlockID? {
        var best: (MaterialBlockID, Double)?
        for block in blocks {
            guard case let .timestamp(start, end) = block.locator else { continue }
            if startSeconds >= start, startSeconds <= end {
                return block.id
            }
            let distance: Double
            if startSeconds < start {
                distance = start - startSeconds
            } else {
                distance = startSeconds - end
            }
            guard distance <= MaterialDigestEvidence.nearbyWindowSeconds else { continue }
            if best == nil || distance < best!.1 {
                best = (block.id, distance)
            }
        }
        return best?.0
    }
}
