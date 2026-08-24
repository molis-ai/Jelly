import Foundation
import WorkspaceDomain

struct MaterialSourceDescriptor: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case bilibiliVideo
        case xiaoyuzhouEpisode
        case publicWebArticle
        case xiaohongshuNote(noteID: String)
        case localText
        case localFile
    }

    let kind: Kind
}

enum MaterialSourceResolver {
    static func resolve(_ inspiration: Inspiration) -> MaterialSource? {
        switch inspiration.inputKind {
        case .url:
            guard let url = inspiration.rawURL else { return nil }
            return MaterialSource(
                inspirationID: inspiration.id,
                url: url,
                kind: inspiration.resolvedSourceKind,
                sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
                sourceTitle: inspiration.resolvedMetadata?.title,
                descriptor: MaterialSourceDescriptor(kind: descriptorKind(for: url))
            )
        case .text:
            guard let text = inspiration.rawText else { return nil }
            return MaterialSource(
                inspirationID: inspiration.id,
                text: text,
                sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration)
            )
        case .file:
            guard let file = inspiration.rawFile else { return nil }
            return MaterialSource(
                inspirationID: inspiration.id,
                file: file,
                kind: inspiration.resolvedSourceKind,
                sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration)
            )
        }
    }

    static func descriptorKind(for url: URL) -> MaterialSourceDescriptor.Kind {
        if let noteID = SourceKindClassifier.xiaohongshuNoteID(for: url) {
            return .xiaohongshuNote(noteID: noteID)
        }
        switch SourceKindClassifier.classify(url) {
        case .video:
            return .bilibiliVideo
        case .audio:
            return .xiaoyuzhouEpisode
        default:
            return .publicWebArticle
        }
    }
}
