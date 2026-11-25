import Foundation
import Testing

@testable import HermesAPI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A scripted reply for `ProjectsURLProtocol`.
struct ProjectsReply: Sendable {
    var status = 200
    var body = Data()
    var failure: URLError?
    /// The final URL of the response, when it differs from the request URL (for example after a redirect).
    var responseURL: URL?
}

/// Intercepts the requests of the projects suite only. It has its own state, so that it does not race with
/// the suites that use `MockURLProtocol` or `SessionsURLProtocol`.
final class ProjectsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> ProjectsReply)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    static func reset() {
        responder = nil
        requests = []
        bodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.readBody(request))
        let reply = Self.responder?(request) ?? ProjectsReply(status: 500)
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: reply.responseURL ?? url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// On Darwin, URLSession hands the body to a URLProtocol as a stream, not as `httpBody`.
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite("SidecarClient projects", .serialized)
struct SidecarProjectsTests {
    private static let projectID = "0b7e8f5c-3a3e-4f0e-9a8e-3f1c2d4b5a69"
    private static let conversationID = "20261120_093000_a1b2c3"

    init() {
        ProjectsURLProtocol.reset()
    }

    private func makeSidecar() -> SidecarClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProjectsURLProtocol.self]
        let base = URL(string: "https://hermes.example.test/sidecar") ?? URL(filePath: "/")
        return SidecarClient(
            configuration: HermesClientConfiguration(baseURL: base, apiKey: "test-key-123"),
            session: URLSession(configuration: config)
        )
    }

    private static func fixture(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return Data() }
        return data
    }

    private static func errorBody(_ code: String, _ message: String = "message") -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }

    private func onlyRequest() throws -> URLRequest {
        #expect(ProjectsURLProtocol.requests.count == 1)
        return try #require(ProjectsURLProtocol.requests.first)
    }

    private func bodyJSON() throws -> [String: String] {
        let body = try #require(ProjectsURLProtocol.bodies.first)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
    }

    // MARK: Routes

    @Test("listing is an authenticated GET to {sidecar}/projects that decodes every project, unknown fields ignored")
    func list() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(body: Self.fixture("projects_list")) }

        let projects = try await makeSidecar().listProjects()

        let request = try onlyRequest()
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://hermes.example.test/sidecar/projects")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(projects.map(\.name) == ["Hermes", "personal"])
        #expect(projects.first == Project(
            id: Self.projectID,
            name: "Hermes",
            repositories: [
                ProjectRepository(
                    id: "5d1c7a2e-9b0f-4c3d-8e6a-1f2b3c4d5e6f",
                    name: "owner/hermes-client",
                    url: "https://git.example.test/owner/hermes-client"
                ),
            ],
            conversationIDs: ["20261120_093000_a1b2c3", "20261119_180000_d4e5f6"]
        ))
        #expect(projects.last?.repositories.isEmpty == true)
        #expect(projects.last?.conversationIDs.isEmpty == true)
    }

    @Test("a project without repositories or conversation_ids decodes with empty lists")
    func missingLists() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(body: Data(#"[{"id":"p1","name":"Bare"}]"#.utf8)) }
        let projects = try await makeSidecar().listProjects()
        #expect(projects == [Project(id: "p1", name: "Bare")])
    }

    @Test("creating is a POST to {sidecar}/projects with the name as JSON, and returns the new project")
    func create() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 201, body: Self.fixture("project")) }

        let project = try await makeSidecar().createProject(name: "Hermes")

        let request = try onlyRequest()
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://hermes.example.test/sidecar/projects")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(try bodyJSON() == ["name": "Hermes"])
        #expect(project == Project(id: Self.projectID, name: "Hermes"))
    }

    @Test("renaming is a PATCH to {sidecar}/projects/{id} with the name, and returns the project")
    func rename() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(body: Self.fixture("project")) }

        let project = try await makeSidecar().renameProject(projectID: Self.projectID, name: "Hermes")

        let request = try onlyRequest()
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://hermes.example.test/sidecar/projects/\(Self.projectID)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try bodyJSON() == ["name": "Hermes"])
        #expect(project.name == "Hermes")
    }

    @Test("deleting is a DELETE to {sidecar}/projects/{id} answered 204")
    func delete() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 204) }

        try await makeSidecar().deleteProject(projectID: Self.projectID)

        let request = try onlyRequest()
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://hermes.example.test/sidecar/projects/\(Self.projectID)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
    }

    @Test("attaching is a PUT to {sidecar}/projects/{id}/conversations/{conversation_id} answered 204")
    func attach() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 204) }

        try await makeSidecar().attachConversation(conversationID: Self.conversationID, projectID: Self.projectID)

        let request = try onlyRequest()
        #expect(request.httpMethod == "PUT")
        #expect(
            request.url?.absoluteString
                == "https://hermes.example.test/sidecar/projects/\(Self.projectID)/conversations/\(Self.conversationID)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
    }

    @Test("detaching is a DELETE to {sidecar}/projects/{id}/conversations/{conversation_id} answered 204")
    func detach() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 204) }

        try await makeSidecar().detachConversation(conversationID: Self.conversationID, projectID: Self.projectID)

        let request = try onlyRequest()
        #expect(request.httpMethod == "DELETE")
        #expect(
            request.url?.absoluteString
                == "https://hermes.example.test/sidecar/projects/\(Self.projectID)/conversations/\(Self.conversationID)")
    }

    // MARK: Errors

    @Test("409 project_name_taken maps to nameTaken, 422 invalid_name to invalidName with the sidecar's reason")
    func nameErrors() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 409, body: Self.errorBody("project_name_taken")) }
        await #expect(throws: ProjectError.nameTaken) { try await makeSidecar().createProject(name: "hermes") }

        ProjectsURLProtocol.responder = { _ in
            ProjectsReply(status: 422, body: Self.errorBody("invalid_name", "the name must not be empty"))
        }
        await #expect(throws: ProjectError.invalidName("the name must not be empty")) {
            try await makeSidecar().renameProject(projectID: Self.projectID, name: " ")
        }
    }

    @Test("404 project_not_found maps to projectNotFound, 422 invalid_conversation_id to invalidConversationID")
    func projectAndConversationErrors() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 404, body: Self.errorBody("project_not_found")) }
        await #expect(throws: ProjectError.projectNotFound) {
            try await makeSidecar().deleteProject(projectID: Self.projectID)
        }

        ProjectsURLProtocol.responder = { _ in
            ProjectsReply(status: 422, body: Self.errorBody("invalid_conversation_id"))
        }
        await #expect(throws: ProjectError.invalidConversationID) {
            try await makeSidecar().attachConversation(conversationID: "é", projectID: Self.projectID)
        }
    }

    @Test("a 404 without the project code (a sidecar without projects), 401, 500 and unknown codes map to api errors")
    func otherStatuses() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 404) }
        await #expect(throws: ProjectError.api(.notFound)) { try await makeSidecar().listProjects() }

        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 401, body: Self.errorBody("unauthorized")) }
        await #expect(throws: ProjectError.api(.unauthorized)) { try await makeSidecar().listProjects() }

        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 500, body: Self.errorBody("database_error")) }
        await #expect(throws: ProjectError.api(.http(status: 500))) { try await makeSidecar().listProjects() }

        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 409, body: Self.errorBody("something_new")) }
        await #expect(throws: ProjectError.api(.http(status: 409))) { try await makeSidecar().createProject(name: "x") }
    }

    @Test("a redirected response, a body that is not projects and a transport failure are api errors")
    func contractAndTransportErrors() async throws {
        ProjectsURLProtocol.responder = { _ in
            ProjectsReply(body: Data("[]".utf8), responseURL: URL(string: "https://hermes.example.test/login"))
        }
        await #expect(throws: ProjectError.api(.invalidResponse)) { try await makeSidecar().listProjects() }

        ProjectsURLProtocol.responder = { _ in ProjectsReply(body: Data("<html>Log in</html>".utf8)) }
        await #expect(throws: ProjectError.api(.invalidResponse)) { try await makeSidecar().listProjects() }

        ProjectsURLProtocol.responder = { _ in ProjectsReply(failure: URLError(.timedOut)) }
        await #expect(throws: ProjectError.api(.timeout)) { try await makeSidecar().listProjects() }

        ProjectsURLProtocol.responder = { _ in ProjectsReply(failure: URLError(.notConnectedToInternet)) }
        await #expect(throws: ProjectError.api(.network)) { try await makeSidecar().listProjects() }
    }

    @Test("an id that is empty or holds a slash is refused without a request")
    func invalidIDs() async throws {
        await #expect(throws: ProjectError.projectNotFound) {
            try await makeSidecar().deleteProject(projectID: "../status")
        }
        await #expect(throws: ProjectError.projectNotFound) {
            try await makeSidecar().renameProject(projectID: "", name: "x")
        }
        await #expect(throws: ProjectError.invalidConversationID) {
            try await makeSidecar().attachConversation(conversationID: "a/b", projectID: Self.projectID)
        }
        await #expect(throws: ProjectError.invalidConversationID) {
            try await makeSidecar().detachConversation(conversationID: "", projectID: Self.projectID)
        }
        #expect(ProjectsURLProtocol.requests.isEmpty)
    }

    @Test("attaching a repository is a POST to {sidecar}/projects/{id}/repositories with the URL as JSON")
    func attachRepository() async throws {
        let repoJSON = #"{"id":"repo-123","name":"owner/name","url":"https://github.com/owner/name"}"#
        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 201, body: Data(repoJSON.utf8)) }

        let repo = try await makeSidecar().attachRepository(url: "https://github.com/owner/name", projectID: Self.projectID)
        #expect(repo == ProjectRepository(id: "repo-123", name: "owner/name", url: "https://github.com/owner/name"))

        let request = try onlyRequest()
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/sidecar/projects/\(Self.projectID)/repositories")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try bodyJSON() == ["url": "https://github.com/owner/name"])
    }

    @Test("detaching a repository is a DELETE to {sidecar}/projects/{id}/repositories/{repo_id}")
    func detachRepository() async throws {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 204) }

        try await makeSidecar().detachRepository(repositoryID: "repo-123", projectID: Self.projectID)

        let request = try onlyRequest()
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path() == "/sidecar/projects/\(Self.projectID)/repositories/repo-123")
    }

    @Test("repository error codes are mapped to specific project errors")
    func repositoryErrors() async {
        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 409, body: Self.errorBody("repository_already_attached")) }
        await #expect(throws: ProjectError.repositoryAlreadyAttached) {
            try await makeSidecar().attachRepository(url: "x", projectID: Self.projectID)
        }

        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 422, body: Self.errorBody("invalid_repository_url", "the host is missing")) }
        await #expect(throws: ProjectError.invalidRepositoryURL("the host is missing")) {
            try await makeSidecar().attachRepository(url: "x", projectID: Self.projectID)
        }

        ProjectsURLProtocol.responder = { _ in ProjectsReply(status: 404, body: Self.errorBody("repository_not_found")) }
        await #expect(throws: ProjectError.repositoryNotFound) {
            try await makeSidecar().detachRepository(repositoryID: "x", projectID: Self.projectID)
        }
    }

    @Test("project errors have a message for the UI")
    func messages() {
        #expect(ProjectError.nameTaken.errorDescription == "A project with this name already exists.")
        #expect(
            ProjectError.invalidName("the name must not be empty").errorDescription
                == "This name cannot be used: the name must not be empty.")
        #expect(ProjectError.repositoryAlreadyAttached.errorDescription == "This repository is already attached to this project.")
        #expect(ProjectError.invalidRepositoryURL("the host is missing").errorDescription == "This repository URL is not supported: the host is missing.")
        #expect(ProjectError.repositoryNotFound.errorDescription == "This repository is not in this project.")
        #expect(ProjectError.api(.unauthorized).errorDescription == HermesAPIError.unauthorized.errorDescription)
        #expect(ProjectError.api(.notFound).errorDescription?.contains("sidecar") == true)
    }
}
