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

    // MARK: Projects

    /// Every project, sorted by name ignoring case, from `GET {sidecar}/projects`.
    ///
    /// Throws `ProjectError`; cancellation throws `CancellationError`.
    public func listProjects() async throws -> [Project] {
        let data = try await projectRequest(method: "GET", path: SidecarPaths.projects)
        return try decode([Project].self, from: data)
    }

    /// Creates a project, from `POST {sidecar}/projects`, and returns it. The sidecar trims the name; a name
    /// another project has (ignoring case) throws `ProjectError.nameTaken`, a blank or too long one
    /// `ProjectError.invalidName`. The request is never retried automatically.
    public func createProject(name: String) async throws -> Project {
        let body = try JSONEncoder().encode(ProjectNameBody(name: name))
        let data = try await projectRequest(method: "POST", path: SidecarPaths.projects, body: body)
        return try decode(Project.self, from: data)
    }

    /// Renames a project, from `PATCH {sidecar}/projects/{id}`, and returns it. Fails as `createProject(name:)`
    /// does, and with `ProjectError.projectNotFound` for a project that is gone.
    public func renameProject(projectID: String, name: String) async throws -> Project {
        try Self.checkProjectID(projectID)
        let body = try JSONEncoder().encode(ProjectNameBody(name: name))
        let data = try await projectRequest(method: "PATCH", path: SidecarPaths.project(projectID), body: body)
        return try decode(Project.self, from: data)
    }

    /// Deletes a project, from `DELETE {sidecar}/projects/{id}`. Its conversations stay on Hermes, in no project.
    public func deleteProject(projectID: String) async throws {
        try Self.checkProjectID(projectID)
        _ = try await projectRequest(method: "DELETE", path: SidecarPaths.project(projectID))
    }

    /// Puts a conversation in a project, from `PUT {sidecar}/projects/{id}/conversations/{conversation_id}`.
    /// A conversation in another project moves to this one. The sidecar does not check that it exists on Hermes.
    public func attachConversation(conversationID: String, projectID: String) async throws {
        try Self.checkProjectID(projectID)
        try Self.checkConversationID(conversationID)
        _ = try await projectRequest(
            method: "PUT", path: SidecarPaths.projectConversation(projectID: projectID, conversationID: conversationID)
        )
    }

    /// Takes a conversation out of a project, from `DELETE {sidecar}/projects/{id}/conversations/{conversation_id}`.
    /// Succeeds also when it was not in this project.
    public func detachConversation(conversationID: String, projectID: String) async throws {
        try Self.checkProjectID(projectID)
        try Self.checkConversationID(conversationID)
        _ = try await projectRequest(
            method: "DELETE",
            path: SidecarPaths.projectConversation(projectID: projectID, conversationID: conversationID)
        )
    }

    /// Sends a project request and returns the body of a 2xx response that was not redirected. Error bodies
    /// map to `ProjectError`; cancellation throws `CancellationError`.
    private func projectRequest(method: String, path: String, body: Data? = nil) async throws -> Data {
        do {
            var request = client.makeRequest(method: method, path: path, accept: "application/json")
            request.httpBody = body
            let (data, response) = try await client.sessionForSidecar.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                throw ProjectError.api(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ProjectError.from(status: http.statusCode, body: data)
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProjectError.from(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProjectError.api(.invalidResponse)
        }
    }

    /// A project id goes into the path: it must be a single, non-empty segment. Anything else cannot name one.
    private static func checkProjectID(_ projectID: String) throws {
        guard !projectID.isEmpty, !projectID.contains("/") else {
            throw ProjectError.projectNotFound
        }
    }

    /// A conversation id goes into the path: it must be a single, non-empty segment.
    private static func checkConversationID(_ conversationID: String) throws {
        guard !conversationID.isEmpty, !conversationID.contains("/") else {
            throw ProjectError.invalidConversationID
        }
    }

    private struct ProjectNameBody: Encodable {
        let name: String
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

    /// Every project, `GET` (sorted by name ignoring case) or `POST` `{"name"}` (`201` with the new project).
    public static let projects = "/projects"

    /// One project, `GET`, `PATCH` `{"name"}` (the renamed project) or `DELETE` (`204`). Errors are
    /// `{"error": {"code", "message"}}`: `404 project_not_found`, `409 project_name_taken`, `422 invalid_name`.
    public static func project(_ projectID: String) -> String {
        "\(projects)/\(projectID)"
    }

    /// One conversation of a project: `PUT` puts it in (moving it out of another project), `DELETE` takes it
    /// out. Both answer `204`, or `422 invalid_conversation_id`.
    public static func projectConversation(projectID: String, conversationID: String) -> String {
        "\(project(projectID))/conversations/\(conversationID)"
    }
}
