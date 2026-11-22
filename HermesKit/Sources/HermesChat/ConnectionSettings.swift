import Foundation

/// Non-secret connection settings. The API key is stored separately, in a `SecretStore`.
///
/// `model` (with its optional `provider`) is the model every new conversation is locked on. Settings saved
/// by versions that had no model here load with the instance default, `hermes-agent`.
///
/// `sidecarURLString` points at the optional hermes-sidecar, which adds endpoints Hermes lacks and takes the
/// same API key. It is either an absolute http(s) URL or a path resolved against the instance URL (for
/// example `/sidecar`). `nil` or blank means no sidecar: the app works without one.
public struct ConnectionSettings: Codable, Equatable, Sendable {
    public var baseURLString: String
    public var model: String
    /// Provider slug of `model` (for example `anthropic`). `nil` lets the instance pick the provider.
    public var provider: String?
    /// Sidecar location, absolute or relative to `baseURLString`. `nil` when no sidecar is configured.
    public var sidecarURLString: String?

    public init(
        baseURLString: String,
        model: String = ModelChoice.instanceDefault.model,
        provider: String? = nil,
        sidecarURLString: String? = nil
    ) {
        self.baseURLString = baseURLString
        self.model = model
        self.provider = provider
        self.sidecarURLString = sidecarURLString
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try container.decode(String.self, forKey: .baseURLString)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ModelChoice.instanceDefault.model
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        sidecarURLString = try container.decodeIfPresent(String.self, forKey: .sidecarURLString)
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

    /// The sidecar base URL, or `nil` when no sidecar is configured or its location does not resolve.
    public var sidecarURL: URL? {
        Self.parseSidecarURL(sidecarURLString ?? "", baseURLString: baseURLString)
    }

    /// `true` when a sidecar location is filled in (valid or not).
    public var hasSidecar: Bool {
        !(sidecarURLString ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Resolves a sidecar location: an absolute http(s) URL with a host, or a path (`/sidecar`, `sidecar`)
    /// appended to the instance URL. Returns `nil` for blank text, other schemes, or a path when the
    /// instance URL is invalid. A trailing slash is dropped so endpoint paths can be appended.
    public static func parseSidecarURL(_ text: String, baseURLString: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            return parseBaseURL(trimmed).map(dropTrailingSlash)
        }
        guard let base = parseBaseURL(baseURLString),
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        guard !path.contains(where: { $0.isWhitespace || $0 == "?" || $0 == "#" }) else { return nil }
        components.path = basePath + path
        components.query = nil
        components.fragment = nil
        return components.url.map(dropTrailingSlash)
    }

    private static func dropTrailingSlash(_ url: URL) -> URL {
        let text = url.absoluteString
        guard text.hasSuffix("/"), let trimmed = URL(string: String(text.dropLast())), trimmed.host != nil else {
            return url
        }
        return trimmed
    }

    /// `true` when the URL parses, the model name is not blank, and the sidecar, if filled in, resolves.
    public var isValid: Bool {
        Self.parseBaseURL(baseURLString) != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!hasSidecar || sidecarURL != nil)
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
