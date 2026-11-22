import Foundation
import HermesAPI

/// Result of one check run by the "Test connection" button in the settings screen.
public enum ConnectionTestOutcome: Sendable, Equatable {
    /// The service answered its check. `detail` is shown after "OK" (for example the sidecar version).
    case succeeded(detail: String? = nil)
    /// The URL is not an absolute http or https URL with a host (or, for the sidecar, a path on it).
    case invalidURL
    /// The API key field is empty.
    case missingKey
    /// The check failed with a typed error.
    case failed(HermesAPIError)
    /// The check was cancelled (for example, the settings screen was dismissed). Nothing to show.
    case cancelled

    public static let succeeded = ConnectionTestOutcome.succeeded(detail: nil)

    public var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }

    /// Text shown under the button, or `nil` when nothing should be shown.
    public var message: String? {
        switch self {
        case .succeeded(let detail):
            detail.map { "OK (\($0))" } ?? "OK"
        case .invalidURL:
            "Enter an http or https URL with a host."
        case .missingKey:
            "Enter the API key."
        case .failed(let error):
            error.errorDescription
        case .cancelled:
            nil
        }
    }
}

/// Results of "Test connection": Hermes always, the sidecar only when one is configured.
public struct ConnectionTestReport: Sendable, Equatable {
    public var hermes: ConnectionTestOutcome
    /// `nil` when no sidecar is configured.
    public var sidecar: ConnectionTestOutcome?

    public init(hermes: ConnectionTestOutcome, sidecar: ConnectionTestOutcome? = nil) {
        self.hermes = hermes
        self.sidecar = sidecar
    }

    /// `true` when a check was cancelled: the screen shows nothing.
    public var isCancelled: Bool {
        hermes == .cancelled || sidecar == .cancelled
    }

    /// Line shown for Hermes, or `nil` when nothing should be shown.
    public var hermesMessage: String? {
        hermes.message.map { "Hermes: \($0)" }
    }

    /// Line shown for the sidecar, or `nil` when there is no sidecar or nothing to show.
    public var sidecarMessage: String? {
        guard let sidecar else { return nil }
        switch sidecar {
        case .invalidURL:
            return "Sidecar: enter a path (for example /sidecar) or an http or https URL."
        case .failed(.http(status: 502)):
            return "Sidecar: it answered but cannot reach Hermes (502)."
        case .failed(.notFound):
            return "Sidecar: not found (404). Check the sidecar path."
        case .failed(.unauthorized):
            return "Sidecar: API key rejected (401). It must be the same key as Hermes."
        default:
            return sidecar.message.map { "Sidecar: \($0)" }
        }
    }
}

/// Runs the connection test from the values typed in the settings screen, without saving them.
public enum ConnectionTester {
    /// Builds clients from the typed values, then runs `HermesClient.checkConnection()` (authenticated) and, when a sidecar is
    /// filled in, `SidecarClient.status()`, in parallel. A blank sidecar is not checked.
    public static func run(
        baseURLString: String, apiKey: String, sidecarURLString: String? = nil
    ) async -> ConnectionTestReport {
        let hasSidecar = !(sidecarURLString ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ConnectionTestReport(hermes: .missingKey)
        }
        let baseURL = ConnectionSettings.parseBaseURL(baseURLString)
        let sidecarURL = ConnectionSettings.parseSidecarURL(sidecarURLString ?? "", baseURLString: baseURLString)

        async let hermes = checkHermes(baseURL: baseURL, apiKey: apiKey)
        async let sidecar = hasSidecar ? checkSidecar(url: sidecarURL, apiKey: apiKey) : nil
        return await ConnectionTestReport(hermes: hermes, sidecar: sidecar)
    }

    private static func checkHermes(baseURL: URL?, apiKey: String) async -> ConnectionTestOutcome {
        guard let baseURL else { return .invalidURL }
        let client = HermesClient(configuration: HermesClientConfiguration(baseURL: baseURL, apiKey: apiKey))
        do {
            try await client.checkConnection()
            return .succeeded
        } catch {
            return outcome(for: error)
        }
    }

    private static func checkSidecar(url: URL?, apiKey: String) async -> ConnectionTestOutcome {
        guard let url else { return .invalidURL }
        let client = SidecarClient(configuration: HermesClientConfiguration(baseURL: url, apiKey: apiKey))
        do {
            let status = try await client.status()
            return .succeeded(detail: status.version.isEmpty ? nil : "v\(status.version)")
        } catch {
            return outcome(for: error)
        }
    }

    /// Maps an error thrown by a check to an outcome. Cancellation is kept apart from failures.
    static func outcome(for error: any Error) -> ConnectionTestOutcome {
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return .cancelled
        }
        return .failed(HermesAPIError.from(error))
    }
}
