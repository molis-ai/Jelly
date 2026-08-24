import Foundation
import Observation

enum DigestSettingsNormalization {
    static func endpoint(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }
        components.scheme = "https"
        guard let normalized = components.url?.absoluteString else { return nil }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    static func model(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum DigestRuntimeConfiguration {
    static func isConfigured(endpoint: String, model: String, secret: String?) -> Bool {
        DigestSettingsNormalization.endpoint(endpoint) != nil
            && DigestSettingsNormalization.model(model) != nil
            && !(secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum DigestSettingsDefaults {
    enum ResolutionError: Error { case unavailable }

    static func resolve(environment: [String: String], dataRoot: URL) throws -> UserDefaults {
        let namespace = DigestCredentialService.resolve(
            environment: environment,
            dataRoot: dataRoot
        )
        guard namespace != DigestCredentialService.production else { return .standard }
        guard let defaults = UserDefaults(suiteName: namespace) else {
            throw ResolutionError.unavailable
        }
        return defaults
    }
}

@Observable
final class DigestSettingsStore {
    static let endpointKey = "digest.endpoint.v1"
    static let modelKey = "digest.model.v1"

    private let defaults: UserDefaults
    private(set) var endpoint: String
    private(set) var model: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endpoint = defaults.string(forKey: Self.endpointKey) ?? ""
        model = defaults.string(forKey: Self.modelKey) ?? ""
    }

    @discardableResult
    func save(endpoint rawEndpoint: String, model rawModel: String) -> Bool {
        guard let normalizedEndpoint = DigestSettingsNormalization.endpoint(rawEndpoint),
              let normalizedModel = DigestSettingsNormalization.model(rawModel)
        else { return false }
        defaults.set(normalizedEndpoint, forKey: Self.endpointKey)
        defaults.set(normalizedModel, forKey: Self.modelKey)
        endpoint = normalizedEndpoint
        model = normalizedModel
        return true
    }
}
