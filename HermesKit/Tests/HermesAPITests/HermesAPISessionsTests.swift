import Foundation
import Testing

@testable import HermesAPI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A scripted reply for `SessionsURLProtocol`.
struct SessionsReply: Sendable {
    var status = 200
    var body = Data()
    var failure: URLError?
    /// The final URL of the response, when it differs from the request URL (for example after a redirect).
    var responseURL: URL?
}

/// Intercepts the requests of the sessions suite only. It has its own state, so that it does not
/// race with the suites that use `MockURLProtocol`.
final class SessionsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> SessionsReply)?
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
        let reply = Self.responder?(request) ?? SessionsReply(status: 500)
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

@Suite("HermesClient.listSessions", .serialized)
struct HermesAPISessionsTests {
    let baseURL = URL(string: "https://hermes.example.test") ?? URL(filePath: "/")

    init() {
        SessionsURLProtocol.reset()
    }

    func makeClient(baseURL: URL? = nil) -> HermesClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionsURLProtocol.self]
        return HermesClient(
            configuration: HermesClientConfiguration(
                baseURL: baseURL ?? self.baseURL, apiKey: "test-key-123"
            ),
            session: URLSession(configuration: config)
        )
    }

    private func fixtureData() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "sessions_list", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test("the request is an authenticated GET to /api/sessions with limit and offset")
    func requestShape() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! fixtureData()) }

        _ = try await makeClient().listSessions(limit: 20, offset: 40)

        let request = try #require(SessionsURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.url?.absoluteString == "https://hermes.example.test/api/sessions?limit=20&offset=40")
        #expect(SessionsURLProtocol.requests.first?.httpMethod == "GET")
    }

    @Test("the default page is limit 50, offset 0")
    func defaultPage() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! fixtureData()) }

        _ = try await makeClient().listSessions()

        let request = try #require(SessionsURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://hermes.example.test/api/sessions?limit=50&offset=0")
    }

    @Test("limit is clamped to 1...200 and offset to 0 or more")
    func clampsPagination() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! fixtureData()) }
        let client = makeClient()

        _ = try await client.listSessions(limit: 0, offset: -5)
        _ = try await client.listSessions(limit: 999)

        let urls = SessionsURLProtocol.requests.compactMap { $0.url?.absoluteString }
        #expect(urls == [
            "https://hermes.example.test/api/sessions?limit=1&offset=0",
            "https://hermes.example.test/api/sessions?limit=200&offset=0",
        ])
    }

    @Test("a base URL with a trailing slash does not produce a double slash")
    func trailingSlashBaseURL() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! fixtureData()) }
        let base = URL(string: "https://hermes.example.test/") ?? URL(filePath: "/")

        _ = try await makeClient(baseURL: base).listSessions()

        let request = try #require(SessionsURLProtocol.requests.first)
        #expect(request.url?.absoluteString.contains("//api") == false)
        #expect(request.url?.path == "/api/sessions")
    }

    @Test("the page decodes sessions, dates and has_more; unknown and absent fields are tolerated")
    func decodesPage() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! fixtureData()) }

        let page = try await makeClient().listSessions()

        #expect(page.hasMore)
        #expect(page.sessions.count == 2)

        let first = page.sessions[0]
        #expect(first.id == "20261120_093000_a1b2c3")
        #expect(first.title == "Release notes draft")
        #expect(first.startedAt == Date(timeIntervalSince1970: 1_795_157_400))
        #expect(first.lastActive == Date(timeIntervalSince1970: 1_795_161_000.5))
        #expect(first.pinned)
        #expect(first.source == "api_server")
        #expect(first.model == "hermes-test-model")
        #expect(first.acceptsAPIMessages)

        let second = page.sessions[1]
        #expect(second.id == "20261119_180000_d4e5f6")
        #expect(second.title == nil)
        #expect(second.lastActive == nil)
        #expect(!second.pinned)
        #expect(second.source == "local")
        #expect(second.model == nil)
        #expect(!second.acceptsAPIMessages)
    }

    @Test("a session without a source is assumed to accept API messages")
    func absentSourceAcceptsMessages() {
        #expect(RemoteSession(id: "a").acceptsAPIMessages)
        #expect(!RemoteSession(id: "a", source: "tui").acceptsAPIMessages)
    }

    @Test("a fork is an authenticated POST to /api/sessions/{id}/fork and returns the new session")
    func forkRequest() async throws {
        SessionsURLProtocol.responder = { _ in
            SessionsReply(status: 201, body: Data(#"""
            {"object":"hermes.session","session":{"id":"api_1795187600_ab12cd34","source":"api_server",
            "title":"Dashboard chat #2","parent_session_id":"local-1","pinned":false,"archived":false}}
            """#.utf8))
        }

        let fork = try await makeClient().forkSession(sessionID: "local-1")

        let request = try #require(SessionsURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://hermes.example.test/api/sessions/local-1/fork")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(SessionsURLProtocol.bodies.first == Data("{}".utf8))
        #expect(fork == RemoteSession(id: "api_1795187600_ab12cd34", title: "Dashboard chat #2", source: "api_server"))
        #expect(fork.acceptsAPIMessages)
    }

    @Test("a rejected fork maps to its status error")
    func forkStatusError() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(status: 404) }

        await #expect(throws: HermesAPIError.notFound) {
            _ = try await makeClient().forkSession(sessionID: "gone")
        }
    }

    @Test("a fork of a session id with a slash is rejected before any request is sent")
    func forkRejectsSlash() async throws {
        await #expect(throws: HermesAPIError.invalidResponse) {
            _ = try await makeClient().forkSession(sessionID: "a/b")
        }
        #expect(SessionsURLProtocol.requests.isEmpty)
    }

    @Test("an empty page is valid and has no more pages")
    func emptyPage() async throws {
        SessionsURLProtocol.responder = { _ in
            SessionsReply(body: Data(#"{"object":"list","data":[],"limit":50,"offset":0,"has_more":false}"#.utf8))
        }

        let page = try await makeClient().listSessions()

        #expect(page == SessionPage(sessions: [], hasMore: false))
    }

    @Test("a session without an id is an invalid response")
    func missingIdIsInvalid() async throws {
        SessionsURLProtocol.responder = { _ in
            SessionsReply(body: Data(#"{"data":[{"title":"x"}],"has_more":false}"#.utf8))
        }

        await #expect(throws: HermesAPIError.invalidResponse) {
            try await makeClient().listSessions()
        }
    }

    @Test("401 maps to unauthorized and 404 to notFound")
    func statusErrors() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(status: 401) }
        await #expect(throws: HermesAPIError.unauthorized) {
            try await makeClient().listSessions()
        }

        SessionsURLProtocol.responder = { _ in SessionsReply(status: 404) }
        await #expect(throws: HermesAPIError.notFound) {
            try await makeClient().listSessions()
        }
    }

    @Test("a 503 from the session database maps to an HTTP error")
    func serviceUnavailable() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(status: 503) }

        await #expect(throws: HermesAPIError.http(status: 503)) {
            try await makeClient().listSessions()
        }
    }

    @Test("a redirect (for example to an access gate) is an invalid response, not a list")
    func redirectIsInvalid() async throws {
        let gate = URL(string: "https://hermes.example.test/login") ?? URL(filePath: "/")
        SessionsURLProtocol.responder = { _ in
            SessionsReply(body: try! fixtureData(), responseURL: gate)
        }

        await #expect(throws: HermesAPIError.invalidResponse) {
            try await makeClient().listSessions()
        }
    }

    @Test("a timeout maps to timeout and a dropped connection to network")
    func transportErrors() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(failure: URLError(.timedOut)) }
        await #expect(throws: HermesAPIError.timeout) {
            try await makeClient().listSessions()
        }

        SessionsURLProtocol.responder = { _ in SessionsReply(failure: URLError(.notConnectedToInternet)) }
        await #expect(throws: HermesAPIError.network) {
            try await makeClient().listSessions()
        }
    }

    private static let createdSession = Data(#"""
    {"object":"hermes.session","session":{"id":"api_1795200000_ab12cd34","source":"api_server",
    "model":"claude-opus","title":null,"pinned":false,"archived":false,"has_model_config":true}}
    """#.utf8)

    @Test("a new session is an authenticated POST to /api/sessions that locks the model and its provider")
    func createRequest() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(status: 201, body: Self.createdSession) }

        let session = try await makeClient().createSession(model: "claude-opus", provider: "anthropic")

        let request = try #require(SessionsURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://hermes.example.test/api/sessions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(
            try JSONSerialization.jsonObject(with: SessionsURLProtocol.bodies.first ?? Data()) as? [String: Any]
        )
        #expect(body as NSDictionary == [
            "model": "claude-opus", "provider": "anthropic", "require_model_lock": true,
        ] as NSDictionary)
        #expect(session == RemoteSession(id: "api_1795200000_ab12cd34", source: "api_server", model: "claude-opus"))
    }

    @Test("a new session without a model sends an empty body: the instance picks its model")
    func createWithoutModel() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(status: 201, body: Self.createdSession) }

        _ = try await makeClient().createSession()

        #expect(SessionsURLProtocol.bodies.first == Data("{}".utf8))
    }

    @Test("a rename is a PATCH of the title to /api/sessions/{id} and returns the renamed session")
    func renameRequest() async throws {
        SessionsURLProtocol.responder = { _ in
            SessionsReply(body: Data(#"{"object":"hermes.session","session":{"id":"s1","title":"Budget"}}"#.utf8))
        }

        let session = try await makeClient().renameSession(sessionID: "s1", title: "Budget")

        let request = try #require(SessionsURLProtocol.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://hermes.example.test/api/sessions/s1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(SessionsURLProtocol.bodies.first == Data(#"{"title":"Budget"}"#.utf8))
        #expect(session.title == "Budget")
    }

    @Test("a delete is an authenticated DELETE to /api/sessions/{id}")
    func deleteRequest() async throws {
        SessionsURLProtocol.responder = { _ in
            SessionsReply(body: Data(#"{"object":"hermes.session.deleted","id":"s1","deleted":true}"#.utf8))
        }

        try await makeClient().deleteSession(sessionID: "s1")

        let request = try #require(SessionsURLProtocol.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://hermes.example.test/api/sessions/s1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
    }

    @Test("a delete refused during a turn maps to its status; a slash in the id sends nothing")
    func deleteErrors() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(status: 409) }

        await #expect(throws: HermesAPIError.http(status: 409)) {
            try await makeClient().deleteSession(sessionID: "busy")
        }
        await #expect(throws: HermesAPIError.invalidResponse) {
            try await makeClient().deleteSession(sessionID: "a/b")
        }
        await #expect(throws: HermesAPIError.invalidResponse) {
            _ = try await makeClient().renameSession(sessionID: "a/b", title: "x")
        }
        #expect(SessionsURLProtocol.requests.count == 1)
    }

    @Test("the connection check is an authenticated GET of one session, and a rejected key fails")
    func connectionCheck() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! fixtureData()) }

        try await makeClient().checkConnection()

        let request = try #require(SessionsURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://hermes.example.test/api/sessions?limit=1&offset=0")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")

        SessionsURLProtocol.responder = { _ in SessionsReply(status: 401) }
        await #expect(throws: HermesAPIError.unauthorized) { try await makeClient().checkConnection() }
    }
}
