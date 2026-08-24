import CryptoKit
import Foundation
import Security

protocol DigestCredentialStoring: Sendable {
    func load() throws -> String?
    func save(_ secret: String) throws
    func delete() throws
}

extension DigestCredentialStoring {
    var isConfigured: Bool {
        guard let secret = try? load() else { return false }
        return !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum DigestCredentialStoreError: Error, Equatable {
    case keychain(OSStatus)
}

enum DigestCredentialService {
    static let production = "ai.adeptify.jelly.digest"

    static func resolve(environment: [String: String], dataRoot: URL) -> String {
        guard let acceptanceRoot = environment["JELLY_ACCEPTANCE_DATA_DIRECTORY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !acceptanceRoot.isEmpty
        else { return production }
        let digest = SHA256.hash(data: Data(dataRoot.standardizedFileURL.path.utf8))
        let namespace = digest.map { String(format: "%02x", $0) }.joined()
        return "\(production).acceptance.\(namespace)"
    }
}

struct KeychainDigestCredentialStore: DigestCredentialStoring {
    static let account = "openai-compatible-api-key"
    private let service: String

    init(service: String = DigestCredentialService.production) {
        self.service = service
    }

    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DigestCredentialStoreError.keychain(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(_ secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete()
            return
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw DigestCredentialStoreError.keychain(addStatus) }
            return
        }
        throw DigestCredentialStoreError.keychain(updateStatus)
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DigestCredentialStoreError.keychain(status)
        }
    }
}

final class InMemoryDigestCredentialStore: DigestCredentialStoring, @unchecked Sendable {
    private var secret: String?

    func load() throws -> String? { secret }

    func save(_ secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = trimmed.isEmpty ? nil : trimmed
    }

    func delete() throws {
        secret = nil
    }
}
