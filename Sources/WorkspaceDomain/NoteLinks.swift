import Foundation

/// A link from one note to another lives in the document as an ordinary
/// inline link to `jelly://note/<id>`. Renaming the target keeps it working,
/// Markdown export and sync carry it for free, and no separate index needs to
/// stay consistent: backlinks are derived from the documents.
public enum NoteLinkURL {
    public static let scheme = "jelly"
    public static let host = "note"

    public static func url(for noteID: NoteID) -> URL {
        URL(string: "\(scheme)://\(host)/\(noteID.rawValue.uuidString)")!
    }

    public static func noteID(from url: URL?) -> NoteID? {
        guard let url,
              url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let raw = url.pathComponents.dropFirst().first,
              let uuid = UUID(uuidString: raw)
        else { return nil }
        return NoteID(uuid)
    }
}

public struct NoteBacklink: Identifiable, Equatable, Sendable {
    public var id: String { "\(sourceNoteID.rawValue.uuidString)/\(blockID.rawValue.uuidString)" }
    public let sourceNoteID: NoteID
    public let sourceTitle: String
    public let blockID: BlockID
    /// The whole block the link sits in, trimmed to a readable length.
    public let excerpt: String
    public let sourceIsArchived: Bool

    public init(sourceNoteID: NoteID, sourceTitle: String, blockID: BlockID, excerpt: String, sourceIsArchived: Bool) {
        self.sourceNoteID = sourceNoteID
        self.sourceTitle = sourceTitle
        self.blockID = blockID
        self.excerpt = excerpt
        self.sourceIsArchived = sourceIsArchived
    }
}

public enum NoteLinkIndex {
    public static let excerptLimit = 120

    /// Notes this document links to, in reading order, without duplicates.
    public static func outgoingNoteIDs(in document: BlockDocument) -> [NoteID] {
        var seen = Set<NoteID>()
        var result: [NoteID] = []
        for block in document.blocks {
            for span in block.inlineContent.spans {
                if let id = NoteLinkURL.noteID(from: span.linkURL), seen.insert(id).inserted {
                    result.append(id)
                }
            }
        }
        return result
    }

    /// Every block in other notes that links to `target`, most recently
    /// edited notes first. Links a note makes to itself are not backlinks.
    public static func backlinks(to target: NoteID, in state: WorkspaceState) -> [NoteBacklink] {
        var result: [(Date, NoteBacklink)] = []
        for note in state.notes.values where note.id != target {
            for block in note.document.blocks {
                guard block.inlineContent.spans.contains(where: { NoteLinkURL.noteID(from: $0.linkURL) == target }) else {
                    continue
                }
                let text = block.inlineContent.spans.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let excerpt = text.count <= excerptLimit ? text : String(text.prefix(excerptLimit - 1)) + "…"
                result.append((note.updatedAt, NoteBacklink(
                    sourceNoteID: note.id,
                    sourceTitle: note.title.isEmpty ? "无标题" : note.title,
                    blockID: block.id,
                    excerpt: excerpt,
                    sourceIsArchived: note.archivedAt != nil
                )))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            return lhs.1.id < rhs.1.id
        }.map(\.1)
    }

    /// Candidates for the `[[` picker: title contains the query, most recently
    /// edited first, archived notes last.
    public static func candidates(
        matching query: String,
        in state: WorkspaceState,
        excluding current: NoteID?,
        limit: Int = 8
    ) -> [Note] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.notes.values
            .filter { $0.id != current }
            .filter { needle.isEmpty || $0.title.lowercased().contains(needle) }
            .sorted { lhs, rhs in
                if (lhs.archivedAt == nil) != (rhs.archivedAt == nil) { return lhs.archivedAt == nil }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            }
            .prefix(limit)
            .map { $0 }
    }
}
