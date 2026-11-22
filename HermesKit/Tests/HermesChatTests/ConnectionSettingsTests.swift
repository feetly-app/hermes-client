import Foundation
import Testing

@testable import HermesChat

@Suite("Connection settings")
struct ConnectionSettingsTests {
    @Test("an http or https URL with a host is accepted")
    func acceptsAbsoluteURLs() {
        #expect(ConnectionSettings.parseBaseURL("https://hermes.example.test") != nil)
        #expect(ConnectionSettings.parseBaseURL("  http://192.168.1.10:8642  ") != nil)
    }

    @Test("empty, relative, non-http and hostless URLs are rejected")
    func rejectsInvalidURLs() {
        #expect(ConnectionSettings.parseBaseURL("") == nil)
        #expect(ConnectionSettings.parseBaseURL("hermes.example.test") == nil)
        #expect(ConnectionSettings.parseBaseURL("ftp://hermes.example.test") == nil)
        #expect(ConnectionSettings.parseBaseURL("https://") == nil)
    }

    @Test("settings are valid only with an http or https URL and a non-blank model")
    func validity() {
        #expect(ConnectionSettings(baseURLString: "https://hermes.example.test").isValid)
        #expect(ConnectionSettings(baseURLString: "https://hermes.example.test", model: "opus").isValid)
        #expect(!ConnectionSettings(baseURLString: "https://hermes.example.test", model: "  ").isValid)
        #expect(!ConnectionSettings(baseURLString: "nope").isValid)
    }

    @Test("the model choice is trimmed, drops a blank provider, and defaults to hermes-agent")
    func modelChoice() {
        let url = "https://hermes.example.test"
        #expect(
            ConnectionSettings(baseURLString: url, model: " opus ", provider: " anthropic ").modelChoice
                == ModelChoice(model: "opus", provider: "anthropic"))
        #expect(ConnectionSettings(baseURLString: url, model: "opus", provider: " ").modelChoice == ModelChoice(model: "opus"))
        #expect(ConnectionSettings(baseURLString: url).modelChoice == ModelChoice.instanceDefault)
    }

    @Test("settings saved without a model by an older version load with hermes-agent")
    func loadsSettingsWithoutModel() throws {
        let suite = "test.connection.legacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"baseURLString":"https://hermes.example.test"}"#.utf8), forKey: "connectionSettings")

        let loaded = UserDefaultsSettingsStorage(defaults: defaults).load()

        #expect(loaded == ConnectionSettings(baseURLString: "https://hermes.example.test", model: "hermes-agent"))
    }

    @Test("the storage round-trips settings and returns nil when empty")
    func storageRoundTrip() {
        let suite = "test.connection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = UserDefaultsSettingsStorage(defaults: defaults)

        #expect(storage.load() == nil)
        let settings = ConnectionSettings(baseURLString: "https://hermes.example.test", model: "opus", provider: "anthropic")
        storage.save(settings)
        #expect(storage.load() == settings)
    }
}
