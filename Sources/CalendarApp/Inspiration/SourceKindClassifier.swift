import Foundation
import WorkspaceDomain

enum SourceKindClassifier {
    static func classify(_ url: URL) -> ResolvedSourceKind? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return nil }
        let path = url.path.lowercased()
        if host == "b23.tv" { return .video }
        if (host == "bilibili.com" || host.hasSuffix(".bilibili.com")),
           path.hasPrefix("/video/") { return .video }
        if (host == "xiaoyuzhoufm.com" || host.hasSuffix(".xiaoyuzhoufm.com")),
           path.hasPrefix("/episode/") { return .audio }
        if xiaohongshuNoteID(for: url) != nil { return .socialPost }
        return nil
    }

    static func xiaohongshuNoteID(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com"),
              let encodedPath = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              )?.percentEncodedPath
        else { return nil }
        let components = encodedPath.split(separator: "/", omittingEmptySubsequences: true)
        let rawID: Substring
        if components.count == 2, components[0].lowercased() == "explore" {
            rawID = components[1]
        } else if components.count == 3,
                  components[0].lowercased() == "discovery",
                  components[1].lowercased() == "item" {
            rawID = components[2]
        } else {
            return nil
        }
        guard (1...128).contains(rawID.utf8.count),
              rawID.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              })
        else { return nil }
        return String(rawID)
    }
}
