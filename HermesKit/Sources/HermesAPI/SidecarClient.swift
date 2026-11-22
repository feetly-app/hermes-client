import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What the sidecar reports at `GET /status`.
public struct SidecarStatus: Sendable, Equatable {
    /// Sidecar version, for example `0.1.0`.
    public let version: String
}

/// Client for the optional hermes-sidecar, which adds endpoints Hermes lacks. It takes the same API key as
/// the instance; `configuration.baseURL` is the sidecar base URL (prefix included, for example `…/sidecar`).
public struct SidecarClient: Sendable {
    private let client: HermesClient

    public init(configuration: HermesClientConfiguration, session: URLSession = .shared) {
        client = HermesClient(configuration: configuration, session: session)
    }

    public var configuration: HermesClientConfiguration { client.configuration }

    /// Checks the key and that the sidecar reaches Hermes, from `GET {sidecar}/status`.
    ///
    /// Succeeds only for a 2xx response that was not redirected, whose body reports `sidecar.status` `ok`.
    /// A `502` means the sidecar answered but cannot reach Hermes. Throws `HermesAPIError`; cancellation
    /// throws `CancellationError`.
    public func status() async throws -> SidecarStatus {
        do {
            let request = client.makeRequest(method: "GET", path: SidecarPaths.status, accept: "application/json")
            let (data, response) = try await client.sessionForSidecar.data(for: request)
            try HermesClient.validate(response, requestURL: request.url)
            let body = try JSONDecoder().decode(StatusBody.self, from: data)
            guard body.sidecar.status == "ok" else {
                throw HermesAPIError.invalidResponse
            }
            return SidecarStatus(version: body.sidecar.version ?? "")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HermesAPIError.from(error)
        }
    }

    /// The image a client attached to a message, from `GET {sidecar}/media/{sha256}`.
    ///
    /// `sha256` is the folder name in the message's `[Image attached at: …]` path; the sidecar checks that the
    /// bytes still hash to it. Returns `nil` when the image is gone (`404`), when the sidecar has no media
    /// folder configured (`503`) or for a digest it refuses (`400`). Other failures throw `HermesAPIError`;
    /// cancellation throws `CancellationError`.
    public func media(sha256: String) async throws -> ImageAttachment? {
        let digest = sha256.lowercased()
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return nil }
        do {
            let request = client.makeRequest(method: "GET", path: SidecarPaths.media(sha256: digest), accept: "image/*")
            let (data, response) = try await client.sessionForSidecar.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                throw HermesAPIError.invalidResponse
            }
            if [400, 404, 503].contains(http.statusCode) {
                return nil
            }
            try HermesClient.validate(response, requestURL: request.url)
            let mimeType = http.value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let image = ImageAttachment(mimeType: mimeType, data: data) else {
                throw HermesAPIError.invalidResponse
            }
            return image
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HermesAPIError.from(error)
        }
    }

    private struct StatusBody: Decodable {
        struct Sidecar: Decodable {
            let status: String
            let version: String?
        }

        let sidecar: Sidecar
    }
}

/// Paths of the hermes-sidecar API, relative to the sidecar base URL (the proxy strips its prefix).
public enum SidecarPaths {
    /// Checks the key and that Hermes is reachable: `200` with `{"sidecar": {"status": "ok", ...}}`,
    /// `401` for a rejected key, `502` when Hermes is down.
    public static let status = "/status"

    /// An image attached to a message, by the SHA-256 of its bytes (lowercase hex): `200` with the image,
    /// `404` when it is gone, `503` when the sidecar has no media folder.
    public static func media(sha256: String) -> String {
        "/media/\(sha256)"
    }
}
