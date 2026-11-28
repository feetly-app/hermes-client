import HermesAPI
import HermesChat
import HermesSecurity
import SwiftUI
import Testing

@testable import Hermes

final class InMemorySettingsStorage: SettingsStorage, @unchecked Sendable {
    var stored: ConnectionSettings?
    init(stored: ConnectionSettings? = nil) { self.stored = stored }
    func load() -> ConnectionSettings? { stored }
    func save(_ settings: ConnectionSettings) { stored = settings }
}

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    var secrets: [String: String] = [:]
    init(secrets: [String: String] = [:]) { self.secrets = secrets }
    func read(account: String) throws -> String? {
        secrets[account]
    }
    func write(_ secret: String, account: String) throws {
        secrets[account] = secret
    }
    func delete(account: String) throws {
        secrets.removeValue(forKey: account)
    }
}

@Suite("HermesApp")
struct HermesAppTests {
    @Test("Root view can be instantiated")
    @MainActor
    func contentViewBuilds() {
        _ = ContentView()
    }

    @Test("ConversationsView builds when browser is present")
    @MainActor
    func conversationsViewBuilds() throws {
        let storage = InMemorySettingsStorage(
            stored: ConnectionSettings(baseURLString: "https://hermes.example.test")
        )
        let secrets = InMemorySecretStore(secrets: ["api-key": "test-key"])
        let appState = AppState(settingsStorage: storage, secrets: secrets)
        let browser = try #require(appState.browser)
        let conversationsView = ConversationsView(browser: browser, appState: appState)
        _ = conversationsView.body
    }

    @Test("ConversationListView builds without selection conflict")
    @MainActor
    func conversationListViewBuilds() throws {
        let storage = InMemorySettingsStorage(
            stored: ConnectionSettings(baseURLString: "https://hermes.example.test")
        )
        let secrets = InMemorySecretStore(secrets: ["api-key": "test-key"])
        let appState = AppState(settingsStorage: storage, secrets: secrets)
        let browser = try #require(appState.browser)
        var failure: String?
        let listView = ConversationListView(browser: browser, failure: Binding(get: { failure }, set: { failure = $0 }))
        _ = listView.body
    }
}
