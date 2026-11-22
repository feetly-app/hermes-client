import Foundation
import HermesAPI
import HermesChat
import HermesSecurity
import Observation

/// Composition root: loads the saved settings and builds the browser once the configuration is complete.
@MainActor
@Observable
final class AppState {
    private(set) var settings: ConnectionSettings?
    private(set) var browser: ConversationBrowser?

    private let settingsStorage: any SettingsStorage
    private let secrets: any SecretStore
    private static let apiKeyAccount = "api-key"

    init(
        settingsStorage: any SettingsStorage = UserDefaultsSettingsStorage(),
        secrets: any SecretStore = KeychainSecretStore()
    ) {
        self.settingsStorage = settingsStorage
        self.secrets = secrets
        settings = settingsStorage.load()
        Self.removeLegacySentImages()
        rebuildBrowser()
    }

    var apiKey: String? {
        try? secrets.read(account: Self.apiKeyAccount)
    }

    /// Saves the settings and the key, then builds the browser. Throws if the key cannot be stored.
    func save(settings: ConnectionSettings, apiKey: String) throws {
        try secrets.write(apiKey, account: Self.apiKeyAccount)
        settingsStorage.save(settings)
        self.settings = settings
        rebuildBrowser()
    }

    private func rebuildBrowser() {
        guard let settings,
              settings.isValid,
              let baseURL = ConnectionSettings.parseBaseURL(settings.baseURLString),
              let key = apiKey, !key.isEmpty
        else {
            browser = nil
            return
        }
        let client = HermesClient(configuration: HermesClientConfiguration(baseURL: baseURL, apiKey: key))
        browser = ConversationBrowser(
            remoteSessions: RemoteSessionList(source: client, storedImages: Self.storedImages(settings, apiKey: key)),
            model: settings.modelChoice
        )
    }

    /// Loads the images stored messages name through the sidecar, or `nil` when none is configured: the
    /// instance does not send them back, so they then show as not available.
    private static func storedImages(_ settings: ConnectionSettings, apiKey: String) -> StoredImageLoader? {
        guard let sidecarURL = settings.sidecarURL else { return nil }
        let sidecar = SidecarClient(configuration: HermesClientConfiguration(baseURL: sidecarURL, apiKey: apiKey))
        return StoredImageLoader(fetcher: sidecar, cache: StoredImageCache.inCaches())
    }

    /// Deletes the copies of sent images that earlier versions kept in `Caches/Sent Images`: the sidecar
    /// now serves every stored image.
    static func removeLegacySentImages() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("Sent Images", isDirectory: true))
    }
}
