import Foundation

/// Non-secret connection settings. The API key is stored separately, in a `SecretStore`.
///
/// `model` (with its optional `provider`) is the model every new conversation is locked on. Settings saved
/// by versions that had no model here load with the instance default, `hermes-agent`.
public struct ConnectionSettings: Codable, Equatable, Sendable {
    public var baseURLString: String
    public var model: String
    /// Provider slug of `model` (for example `anthropic`). `nil` lets the instance pick the provider.
    public var provider: String?

    public init(
        baseURLString: String,
        model: String = ModelChoice.instanceDefault.model,
        provider: String? = nil
    ) {
        self.baseURLString = baseURLString
        self.model = model
        self.provider = provider
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try container.decode(String.self, forKey: .baseURLString)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ModelChoice.instanceDefault.model
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
    }

    /// The model new conversations run on: the trimmed model and provider, or the instance default when the
    /// model is blank.
    public var modelChoice: ModelChoice {
        ModelChoice(model: model, provider: provider).normalized ?? .instanceDefault
    }

    /// The base URL if the text is an absolute http(s) URL with a host, otherwise `nil`.
    public static func parseBaseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty
        else {
            return nil
        }
        return url
    }

    /// `true` when the URL parses and the model name is not blank.
    public var isValid: Bool {
        Self.parseBaseURL(baseURLString) != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Persistence of the non-secret settings.
public protocol SettingsStorage: Sendable {
    func load() -> ConnectionSettings?
    func save(_ settings: ConnectionSettings)
}

/// `UserDefaults`-backed storage. Only non-secret values belong here.
public final class UserDefaultsSettingsStorage: SettingsStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "connectionSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ConnectionSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ConnectionSettings.self, from: data)
    }

    public func save(_ settings: ConnectionSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
