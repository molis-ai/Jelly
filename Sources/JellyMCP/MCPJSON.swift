import Foundation

/// Minimal JSON value tree used for MCP JSON-RPC traffic and tool arguments.
/// Kept value-semantic (Equatable + Sendable) so the MCP layer stays testable
/// without pulling in a JSON library dependency.
public enum MCPJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([MCPJSON])
    case object([String: MCPJSON])

    // MARK: Wire decoding / encoding

    public static func parse(_ data: Data) throws -> MCPJSON {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return MCPJSON(from: raw)
    }

    init(from raw: Any) {
        switch raw {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // JSONSerialization bridges every scalar to NSNumber, including
            // booleans; CoreFoundation's type ID is the reliable discriminator.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let exact = Self.exactInt64(of: number) {
                self = .int(exact)
            } else {
                self = .double(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { MCPJSON(from: $0) })
        case let dictionary as [String: Any]:
            var mapped: [String: MCPJSON] = [:]
            mapped.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                mapped[key] = MCPJSON(from: value)
            }
            self = .object(mapped)
        default:
            self = .null
        }
    }

    private static func exactInt64(of number: NSNumber) -> Int64? {
        let double = number.doubleValue
        guard double.rounded() == double else { return nil }
        // Integer storage types (ObjCType c/i/l/q and unsigned variants) are
        // exact at full Int64 range; doubles are only exact up to 2^53.
        let typeCharacter = Character(UnicodeScalar(UInt8(bitPattern: number.objCType.pointee)))
        if "cilqCSIQL".contains(typeCharacter) {
            return number.int64Value
        }
        guard abs(double) <= 9_007_199_254_740_992 else { return nil }
        return Int64(exactly: double)
    }

    /// Canonical wire bytes (sorted keys), used for HTTP bodies and tests.
    public func serialized() -> Data {
        serialize(options: [.sortedKeys, .fragmentsAllowed])
    }

    /// Compact one-line serialization (newline-terminated), used by the bridge.
    public func serializedLine() -> Data {
        serialize(options: [.sortedKeys, .fragmentsAllowed]) + Data([0x0A])
    }

    private func serialize(options: JSONSerialization.WritingOptions) -> Data {
        let raw = MCPJSON.rawObject(for: self)
        return (try? JSONSerialization.data(withJSONObject: raw, options: options)) ?? Data()
    }

    private static func rawObject(for value: MCPJSON) -> Any {
        switch value {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .int(value):
            return NSNumber(value: value)
        case let .double(value):
            return NSNumber(value: value)
        case let .string(value):
            return value
        case let .array(values):
            return values.map { rawObject(for: $0) }
        case let .object(values):
            var mapped: [String: Any] = [:]
            for (key, element) in values {
                mapped[key] = rawObject(for: element)
            }
            return mapped
        }
    }

    // MARK: Accessors

    public var objectValue: [String: MCPJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        if case let .int(value) = self { return value }
        return nil
    }

    public var arrayValue: [MCPJSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    // MARK: Codable argument decoding

    /// Bridges the value tree into `JSONDecoder`-compatible bytes so tool
    /// argument structs can stay plain `Codable` types.
    public func jsonData() -> Data {
        serialize(options: [.fragmentsAllowed])
    }

    public func decode<A: Decodable>(_ type: A.Type) throws -> A {
        try JSONDecoder().decode(A.self, from: jsonData())
    }

    // MARK: Building helpers

    public static func array(_ values: [String]) -> MCPJSON {
        .array(values.map { .string($0) })
    }
}
