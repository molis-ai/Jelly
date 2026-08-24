import Foundation
import Testing
@testable import CalendarApp

@Suite("DigestSettingsTests")
struct DigestSettingsTests {
    @Test func productionCredentialNamespaceRemainsStable() {
        let service = DigestCredentialService.resolve(
            environment: [:],
            dataRoot: URL(fileURLWithPath: "/private/tmp/jelly-production")
        )

        #expect(service == "ai.adeptify.jelly.digest")
    }

    @Test func acceptanceDataDirectoriesUseDistinctCredentialNamespaces() {
        let firstRoot = URL(fileURLWithPath: "/private/tmp/jelly-acceptance-a")
        let secondRoot = URL(fileURLWithPath: "/private/tmp/jelly-acceptance-b")
        let first = DigestCredentialService.resolve(
            environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": firstRoot.path],
            dataRoot: firstRoot
        )
        let second = DigestCredentialService.resolve(
            environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": secondRoot.path],
            dataRoot: secondRoot
        )

        #expect(first != "ai.adeptify.jelly.digest")
        #expect(second != "ai.adeptify.jelly.digest")
        #expect(first != second)
    }

    @Test func acceptanceDataDirectoriesDoNotShareDigestPreferences() throws {
        let firstRoot = URL(fileURLWithPath: "/private/tmp/jelly-settings-a-\(UUID().uuidString)")
        let secondRoot = URL(fileURLWithPath: "/private/tmp/jelly-settings-b-\(UUID().uuidString)")
        let firstDefaults = try DigestSettingsDefaults.resolve(
            environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": firstRoot.path],
            dataRoot: firstRoot
        )
        let secondDefaults = try DigestSettingsDefaults.resolve(
            environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": secondRoot.path],
            dataRoot: secondRoot
        )
        defer {
            for defaults in [firstDefaults, secondDefaults] {
                defaults.removeObject(forKey: DigestSettingsStore.endpointKey)
                defaults.removeObject(forKey: DigestSettingsStore.modelKey)
            }
        }
        let first = DigestSettingsStore(defaults: firstDefaults)
        let second = DigestSettingsStore(defaults: secondDefaults)

        #expect(first.save(endpoint: "https://api.example.com/v1", model: "model-a"))
        #expect(second.endpoint.isEmpty)
        #expect(second.model.isEmpty)
    }

    @Test func inMemoryCredentialsSaveOverwriteDeleteAndNeverTreatEmptyAsConfigured() throws {
        let store = InMemoryDigestCredentialStore()
        #expect(try store.load() == nil)
        #expect(store.isConfigured == false)

        try store.save("secret-one")
        #expect(try store.load() == "secret-one")
        #expect(store.isConfigured)

        try store.save("secret-two")
        #expect(try store.load() == "secret-two")

        try store.save("   ")
        #expect(try store.load() == nil)
        #expect(store.isConfigured == false)

        try store.save("secret-three")
        try store.delete()
        #expect(try store.load() == nil)
        #expect(store.isConfigured == false)
    }

    @Test func endpointMustBeHTTPSWithoutTrailingSlashAndModelMustBeNonempty() {
        #expect(DigestSettingsNormalization.endpoint("https://api.example.com/v1/") == "https://api.example.com/v1")
        #expect(DigestSettingsNormalization.endpoint("https://api.example.com/v1") == "https://api.example.com/v1")
        #expect(DigestSettingsNormalization.endpoint("http://api.example.com/v1") == nil)
        #expect(DigestSettingsNormalization.endpoint("ftp://api.example.com/v1") == nil)
        #expect(DigestSettingsNormalization.endpoint("https://user:secret@api.example.com/v1") == nil)
        #expect(DigestSettingsNormalization.endpoint("https://api.example.com/v1?tenant=secret") == nil)
        #expect(DigestSettingsNormalization.endpoint("https://api.example.com/v1#secret") == nil)
        #expect(DigestSettingsNormalization.endpoint("not-a-url") == nil)
        #expect(DigestSettingsNormalization.model("  gpt-4o-mini  ") == "gpt-4o-mini")
        #expect(DigestSettingsNormalization.model("   ") == nil)
        #expect(
            DigestRuntimeConfiguration.isConfigured(
                endpoint: "https://api.example.com/v1",
                model: "gpt-test",
                secret: "sk-test"
            )
        )
        #expect(
            DigestRuntimeConfiguration.isConfigured(
                endpoint: "https://api.example.com/v1",
                model: "gpt-test",
                secret: nil
            ) == false
        )
        #expect(
            DigestRuntimeConfiguration.isConfigured(
                endpoint: "http://api.example.com/v1",
                model: "gpt-test",
                secret: "sk-test"
            ) == false
        )
    }

    @Test func settingsStorePersistsOnlyNonSecretPreferences() {
        let suite = "jelly-digest-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = DigestSettingsStore(defaults: defaults)
        #expect(store.endpoint.isEmpty)
        #expect(store.model.isEmpty)

        #expect(store.save(endpoint: "https://api.example.com/v1/", model: " gpt-test "))
        #expect(store.endpoint == "https://api.example.com/v1")
        #expect(store.model == "gpt-test")
        #expect(defaults.string(forKey: DigestSettingsStore.endpointKey) == "https://api.example.com/v1")
        #expect(defaults.string(forKey: DigestSettingsStore.modelKey) == "gpt-test")
        #expect(defaults.dictionaryRepresentation().values.contains(where: { ($0 as? String)?.contains("sk-") == true }) == false)

        #expect(store.save(endpoint: "http://insecure.example.com", model: "gpt-test") == false)
        #expect(store.endpoint == "https://api.example.com/v1")
    }
}
