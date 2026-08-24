import Foundation

enum XiaohongshuPageParserError: Error, Equatable {
    case missingInitialState
    case malformedInitialState
    case noteMismatch
    case missingNote
}

struct XiaohongshuImageReference: Equatable, Sendable {
    let index: Int
    let url: URL
}

struct XiaohongshuNotePayload: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case video
        case image
    }

    let noteID: String
    let kind: Kind
    let title: String?
    let body: String?
    let tags: [String]
    let images: [XiaohongshuImageReference]
    let videoCandidateURLs: [URL]
}

enum XiaohongshuPageParser {
    private static let maximumInitialStateCharacters = 2_000_000
    private static let maximumSearchDepth = 16
    private static let maximumSearchNodes = 50_000

    static func parse(
        html: String,
        expectedNoteID: String
    ) throws -> XiaohongshuNotePayload {
        guard !expectedNoteID.isEmpty,
              let raw = extractInitialState(from: html)
        else { throw XiaohongshuPageParserError.missingInitialState }
        guard raw.count <= maximumInitialStateCharacters,
              let object = try? JSONSerialization.jsonObject(
                with: Data(sanitizeJavaScriptObjectLiteral(raw).utf8)
              )
        else { throw XiaohongshuPageParserError.malformedInitialState }

        var candidateIDs = Set<String>()
        var visited = 0
        guard let note = knownNote(
            in: object,
            expectedNoteID: expectedNoteID,
            candidateIDs: &candidateIDs
        ) ?? findNote(
            in: object,
            expectedNoteID: expectedNoteID,
            depth: 0,
            visited: &visited,
            candidateIDs: &candidateIDs
        ) else {
            if !candidateIDs.isEmpty { throw XiaohongshuPageParserError.noteMismatch }
            throw XiaohongshuPageParserError.missingNote
        }

        let title = normalizedText(firstString(in: note, keys: ["title", "displayTitle"]), limit: 500)
        let body = normalizedText(firstString(in: note, keys: ["desc", "description"]), limit: 200_000)
        let tags = parsedTags(note["tagList"] ?? note["tags"])
        let images = parsedImages(note["imageList"] ?? note["images"])
        let videoObject = note["video"] ?? note["videoInfo"]
        let videoURLs = uniqueHTTPSURLs(in: videoObject)
        let declaredType = firstString(in: note, keys: ["type", "noteType"])?.lowercased()
        let kind: XiaohongshuNotePayload.Kind = declaredType == "video" || !videoURLs.isEmpty
            ? .video
            : .image
        return XiaohongshuNotePayload(
            noteID: expectedNoteID,
            kind: kind,
            title: title,
            body: body,
            tags: tags,
            images: images,
            videoCandidateURLs: videoURLs
        )
    }

    private static func extractInitialState(from html: String) -> String? {
        guard let marker = html.range(of: "__INITIAL_STATE__") else { return nil }
        let tail = html[marker.upperBound...]
        guard let assignment = tail.firstIndex(of: "="),
              let brace = tail[assignment...].firstIndex(of: "{")
        else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in tail[brace...].indices {
            let character = tail[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(tail[brace...index]) }
            }
        }
        return nil
    }

    private static func knownNote(
        in object: Any,
        expectedNoteID: String,
        candidateIDs: inout Set<String>
    ) -> [String: Any]? {
        guard let root = object as? [String: Any] else { return nil }
        let containers = [
            (root["note"] as? [String: Any])?["noteDetailMap"],
            root["noteDetailMap"]
        ]
        for container in containers {
            guard let map = container as? [String: Any] else { continue }
            candidateIDs.formUnion(map.keys)
            guard let entry = map[expectedNoteID] else { continue }
            if let wrapper = entry as? [String: Any],
               let note = wrapper["note"] as? [String: Any] {
                if let embeddedID = firstString(
                    in: note,
                    keys: ["noteId", "noteID", "note_id"]
                ) {
                    candidateIDs.insert(embeddedID)
                    guard embeddedID == expectedNoteID else { continue }
                }
                return note
            }
            if let note = entry as? [String: Any] {
                if let embeddedID = firstString(
                    in: note,
                    keys: ["noteId", "noteID", "note_id"]
                ) {
                    candidateIDs.insert(embeddedID)
                    guard embeddedID == expectedNoteID else { continue }
                }
                return note
            }
        }
        return nil
    }

    private static func findNote(
        in value: Any,
        expectedNoteID: String,
        depth: Int,
        visited: inout Int,
        candidateIDs: inout Set<String>
    ) -> [String: Any]? {
        guard depth <= maximumSearchDepth, visited < maximumSearchNodes else { return nil }
        visited += 1
        if let dictionary = value as? [String: Any] {
            if let noteID = firstString(in: dictionary, keys: ["noteId", "noteID", "note_id"]) {
                candidateIDs.insert(noteID)
                if noteID == expectedNoteID { return dictionary }
            }
            for key in dictionary.keys.sorted() {
                if let found = findNote(
                    in: dictionary[key] as Any,
                    expectedNoteID: expectedNoteID,
                    depth: depth + 1,
                    visited: &visited,
                    candidateIDs: &candidateIDs
                ) { return found }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = findNote(
                    in: item,
                    expectedNoteID: expectedNoteID,
                    depth: depth + 1,
                    visited: &visited,
                    candidateIDs: &candidateIDs
                ) { return found }
            }
        }
        return nil
    }

    private static func parsedTags(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        var result: [String] = []
        for item in array {
            let raw: String?
            if let string = item as? String {
                raw = string
            } else if let dictionary = item as? [String: Any] {
                raw = firstString(in: dictionary, keys: ["name", "title"])
            } else {
                raw = nil
            }
            guard let tag = normalizedText(raw, limit: 100), !result.contains(tag) else { continue }
            result.append(tag)
        }
        return result
    }

    private static func parsedImages(_ value: Any?) -> [XiaohongshuImageReference] {
        guard let array = value as? [Any] else { return [] }
        var urls: [URL] = []
        for item in array {
            guard let dictionary = item as? [String: Any],
                  let raw = firstString(
                    in: dictionary,
                    keys: ["urlDefault", "urlPre", "url"]
                  ),
                  let url = safeHTTPSURL(raw),
                  !urls.contains(url)
            else { continue }
            urls.append(url)
        }
        return urls.enumerated().map { offset, url in
            XiaohongshuImageReference(index: offset + 1, url: url)
        }
    }

    private static func uniqueHTTPSURLs(in value: Any?) -> [URL] {
        let acceptedKeys = Set([
            "masterurl", "backupurls", "streamurl", "urldefault", "urlpre", "url"
        ])
        var result: [URL] = []
        func visit(_ value: Any, key: String?, depth: Int) {
            guard depth <= maximumSearchDepth else { return }
            if let raw = value as? String,
               let key,
               acceptedKeys.contains(key.lowercased()),
               let url = safeHTTPSURL(raw),
               !result.contains(url) {
                result.append(url)
                return
            }
            if let dictionary = value as? [String: Any] {
                let preferred = [
                    "masterUrl", "streamUrl", "url", "urlDefault", "urlPre", "backupUrls"
                ]
                let orderedKeys = preferred.filter { dictionary[$0] != nil }
                    + dictionary.keys.filter { !preferred.contains($0) }.sorted()
                for childKey in orderedKeys {
                    visit(dictionary[childKey] as Any, key: childKey, depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                for item in array { visit(item, key: key, depth: depth + 1) }
            }
        }
        if let value { visit(value, key: nil, depth: 0) }
        return result
    }

    private static func firstString(
        in dictionary: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String { return value }
        }
        return nil
    }

    private static func normalizedText(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(limit))
    }

    private static func safeHTTPSURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil
        else { return nil }
        return url
    }

    private static func sanitizeJavaScriptObjectLiteral(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.count)
        var inString = false
        var escaped = false
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = raw.index(after: index)
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index = raw.index(after: index)
                continue
            }
            if replaceJavaScriptLiteral(
                named: "undefined",
                in: raw,
                at: &index,
                output: &output
            ) { continue }
            output.append(character)
            index = raw.index(after: index)
        }
        return output
    }

    private static func replaceJavaScriptLiteral(
        named token: String,
        in raw: String,
        at index: inout String.Index,
        output: inout String
    ) -> Bool {
        guard raw[index...].hasPrefix(token) else { return false }
        let end = raw.index(index, offsetBy: token.count, limitedBy: raw.endIndex) ?? raw.endIndex
        let previous = output.last
        let next = end < raw.endIndex ? raw[end] : " "
        let previousIsBoundary = previous == nil
            || !(previous!.isLetter || previous!.isNumber || previous == "_")
        let nextIsBoundary = !next.isLetter && !next.isNumber && next != "_"
        guard previousIsBoundary, nextIsBoundary else { return false }
        output.append("null")
        index = end
        return true
    }
}
