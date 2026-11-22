import Foundation
import Testing

@testable import HermesAPI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A scripted reply returned by `MockURLProtocol`.
struct MockReply: Sendable {
    var status = 200
    var chunks: [Data] = []
    /// `false`: the response stays open (useful to test cancellation).
    var finish = true
    var failure: URLError?
    /// The final URL of the response, when it differs from the request URL (for example after a redirect).
    var responseURL: URL?
    var headers: [String: String]?
}

/// Intercepts the requests of the test session. Global state: the suite is `.serialized`.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> MockReply)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var stopCount = 0

    static func reset() {
        responder = nil
        requests = []
        bodies = []
        stopCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.readBody(request))

        let reply = Self.responder?(request) ?? MockReply(status: 500)
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: reply.responseURL ?? url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if reply.finish {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.stopCount += 1
    }

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

@Suite("HermesClient", .serialized)
struct HermesClientTests {
    private let baseURL = URL(string: "https://hermes.example.test") ?? URL(filePath: "/")
    private let apiKey = "test-key-123"

    init() {
        MockURLProtocol.reset()
    }

    private func makeClient(baseURL: URL? = nil) -> HermesClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return HermesClient(
            configuration: HermesClientConfiguration(baseURL: baseURL ?? self.baseURL, apiKey: apiKey),
            session: session
        )
    }

    private func fixtureData(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    @Test("the health check is an authenticated GET to /health, without a body")
    func healthRequestShape() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: [Data(#"{"status":"ok"}"#.utf8)]) }

        try await makeClient().healthCheck()

        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://hermes.example.test/health")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(MockURLProtocol.bodies.first?.isEmpty == true)
    }

    @Test("a JSON object body with a 200 status is a successful health check")
    func healthSuccess() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: [Data(#"{"status":"ok"}"#.utf8)]) }
        try await makeClient().healthCheck()
    }

    @Test("a base URL with a trailing slash does not produce a double slash in the health check")
    func healthTrailingSlash() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: [Data(#"{"status":"ok"}"#.utf8)]) }
        let base = URL(string: "https://hermes.example.test/") ?? URL(filePath: "/")
        try await makeClient(baseURL: base).healthCheck()
        #expect(MockURLProtocol.requests.first?.url?.absoluteString == "https://hermes.example.test/health")
    }

    @Test("a non-JSON body (for example an HTML login page) maps to invalidResponse")
    func healthHTMLBody() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: [Data("<html>Log in</html>".utf8)]) }
        await #expect(throws: HermesAPIError.invalidResponse) {
            try await makeClient().healthCheck()
        }
    }

    @Test("a JSON body that is not an object maps to invalidResponse")
    func healthNonObjectBody() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: [Data("[1,2]".utf8)]) }
        await #expect(throws: HermesAPIError.invalidResponse) {
            try await makeClient().healthCheck()
        }
    }

    @Test("an empty 200 body maps to invalidResponse")
    func healthEmptyBody() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: []) }
        await #expect(throws: HermesAPIError.invalidResponse) {
            try await makeClient().healthCheck()
        }
    }

    @Test("a response served from another URL (access gate redirect) maps to invalidResponse")
    func healthRedirectedResponse() async throws {
        let login = URL(string: "https://hermes.example.test/login") ?? URL(filePath: "/")
        MockURLProtocol.responder = { _ in
            MockReply(chunks: [Data(#"{"status":"ok"}"#.utf8)], responseURL: login)
        }
        await #expect(throws: HermesAPIError.invalidResponse) {
            try await makeClient().healthCheck()
        }
    }

    @Test("a 302 status (redirect not followed) maps to http(status: 302)")
    func healthRedirectStatus() async throws {
        MockURLProtocol.responder = { _ in MockReply(status: 302) }
        await #expect(throws: HermesAPIError.http(status: 302)) {
            try await makeClient().healthCheck()
        }
    }

    @Test("health: 401 maps to unauthorized, 404 to notFound, 500 to http(status:)")
    func healthStatusErrors() async throws {
        MockURLProtocol.responder = { _ in MockReply(status: 401) }
        await #expect(throws: HermesAPIError.unauthorized) {
            try await makeClient().healthCheck()
        }
        MockURLProtocol.responder = { _ in MockReply(status: 404) }
        await #expect(throws: HermesAPIError.notFound) {
            try await makeClient().healthCheck()
        }
        MockURLProtocol.responder = { _ in MockReply(status: 500) }
        await #expect(throws: HermesAPIError.http(status: 500)) {
            try await makeClient().healthCheck()
        }
    }

    @Test("health: URLError.timedOut maps to timeout, and a connection failure to network")
    func healthTransportErrors() async throws {
        MockURLProtocol.responder = { _ in MockReply(failure: URLError(.timedOut)) }
        await #expect(throws: HermesAPIError.timeout) {
            try await makeClient().healthCheck()
        }
        MockURLProtocol.responder = { _ in MockReply(failure: URLError(.cannotConnectToHost)) }
        await #expect(throws: HermesAPIError.network) {
            try await makeClient().healthCheck()
        }
    }

    @Test("listModels: a 200 with data[].id returns the IDs in order")
    func listModelsSuccess() async throws {
        let json = Data(#"{"object":"list","data":[{"id":"hermes-agent","object":"model"},{"id":"fast","object":"model"}]}"#.utf8)
        MockURLProtocol.responder = { _ in MockReply(chunks: [json]) }

        let result = try await makeClient().listModels()

        #expect(result == .models(["hermes-agent", "fast"]))
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://hermes.example.test/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(MockURLProtocol.bodies.first?.isEmpty == true)
    }

    @Test("listModels: a 404 returns the fallback with notFound")
    func listModelsNotFound() async throws {
        MockURLProtocol.responder = { _ in MockReply(status: 404) }
        let result = try await makeClient().listModels()
        #expect(result == .fallback(.notFound))
    }

    @Test("listModels: a network failure returns the fallback with network")
    func listModelsNetwork() async throws {
        MockURLProtocol.responder = { _ in MockReply(failure: URLError(.cannotConnectToHost)) }
        let result = try await makeClient().listModels()
        #expect(result == .fallback(.network))
    }

    @Test("listModels: a timeout returns the fallback with timeout")
    func listModelsTimeout() async throws {
        MockURLProtocol.responder = { _ in MockReply(failure: URLError(.timedOut)) }
        let result = try await makeClient().listModels()
        #expect(result == .fallback(.timeout))
    }

    @Test("listModels: a 401 returns the fallback with unauthorized")
    func listModelsUnauthorized() async throws {
        MockURLProtocol.responder = { _ in MockReply(status: 401) }
        let result = try await makeClient().listModels()
        #expect(result == .fallback(.unauthorized))
    }

    @Test("listModels: a non-JSON body (login page) returns the fallback with invalidResponse")
    func listModelsHTMLBody() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: [Data("<html>Log in</html>".utf8)]) }
        let result = try await makeClient().listModels()
        #expect(result == .fallback(.invalidResponse))
    }

    @Test("listModels: a JSON body without data[].id returns the fallback with invalidResponse")
    func listModelsUnexpectedJSON() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: [Data(#"{"models":["a"]}"#.utf8)]) }
        let result = try await makeClient().listModels()
        #expect(result == .fallback(.invalidResponse))
    }

    @Test("listModels: an empty data array returns the fallback with invalidResponse")
    func listModelsEmpty() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: [Data(#"{"object":"list","data":[]}"#.utf8)]) }
        let result = try await makeClient().listModels()
        #expect(result == .fallback(.invalidResponse))
    }

    @Test("listModels: a response served from another URL returns the fallback with invalidResponse")
    func listModelsRedirected() async throws {
        let login = URL(string: "https://hermes.example.test/login") ?? URL(filePath: "/")
        MockURLProtocol.responder = { _ in
            MockReply(chunks: [Data(#"{"object":"list","data":[{"id":"a"}]}"#.utf8)], responseURL: login)
        }
        let result = try await makeClient().listModels()
        #expect(result == .fallback(.invalidResponse))
    }
    @Test("listModelOptions: providers grouped as listed, without unusable ones or unavailable models")
    func listModelOptionsSuccess() async throws {
        let json = try fixtureData("model_options", "json")
        MockURLProtocol.responder = { _ in MockReply(chunks: [json]) }

        let result = try await makeClient().listModelOptions()

        #expect(
            result
                == .options(
                    ModelOptions(
                        providers: [
                            ModelProviderOption(
                                slug: "anthropic", name: "Anthropic",
                                models: ["claude-opus-test", "claude-sonnet-test"], isCurrent: true),
                            ModelProviderOption(slug: "openai", name: "OpenAI", models: ["gpt-test"]),
                        ],
                        currentModel: "claude-opus-test",
                        currentProvider: "anthropic"
                    )))
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(
            request.url?.absoluteString
                == "https://hermes.example.test/api/model/options?include_unconfigured=false")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
    }

    @Test("listModelOptions: a 404 returns the fallback with notFound")
    func listModelOptionsNotFound() async throws {
        MockURLProtocol.responder = { _ in MockReply(status: 404) }
        let result = try await makeClient().listModelOptions()
        #expect(result == .fallback(.notFound))
    }

    @Test("listModelOptions: a login page returns the fallback with invalidResponse")
    func listModelOptionsHTML() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: [Data("<html>Log in</html>".utf8)]) }
        let result = try await makeClient().listModelOptions()
        #expect(result == .fallback(.invalidResponse))
    }

    @Test("listModelOptions: a catalog with no usable provider returns the fallback with invalidResponse")
    func listModelOptionsNoUsableProvider() async throws {
        let json = Data(#"{"providers":[{"slug":"xai","models":["grok"],"authenticated":false}]}"#.utf8)
        MockURLProtocol.responder = { _ in MockReply(chunks: [json]) }
        let result = try await makeClient().listModelOptions()
        #expect(result == .fallback(.invalidResponse))
    }
}

// Sidecar tests share `MockURLProtocol`, so they run in this serialized suite.
extension HermesClientTests {
    private func makeSidecar(_ base: String = "https://hermes.example.test/sidecar") -> SidecarClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return SidecarClient(
            configuration: HermesClientConfiguration(baseURL: URL(string: base) ?? baseURL, apiKey: apiKey),
            session: URLSession(configuration: config)
        )
    }

    private static let sidecarOK = Data(
        #"{"sidecar":{"status":"ok","version":"0.1.0"},"hermes":{"reachable":true,"health":{"status":"ok"}}}"#.utf8)

    @Test("the sidecar status is an authenticated GET to {sidecar}/status that returns the version")
    func sidecarStatusRequest() async throws {
        MockURLProtocol.responder = { _ in MockReply(chunks: [Self.sidecarOK]) }

        let status = try await makeSidecar().status()

        #expect(status == SidecarStatus(version: "0.1.0"))
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://hermes.example.test/sidecar/status")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
    }

    @Test("a rejected key, Hermes down (502) and a body without status ok are sidecar failures")
    func sidecarStatusFailures() async throws {
        MockURLProtocol.responder = { _ in MockReply(status: 401) }
        await #expect(throws: HermesAPIError.unauthorized) { try await makeSidecar().status() }

        MockURLProtocol.responder = { _ in MockReply(status: 502) }
        await #expect(throws: HermesAPIError.http(status: 502)) { try await makeSidecar().status() }

        MockURLProtocol.responder = { _ in MockReply(chunks: [Data(#"{"status":"ok"}"#.utf8)]) }
        await #expect(throws: HermesAPIError.invalidResponse) { try await makeSidecar().status() }

        MockURLProtocol.responder = { _ in MockReply(chunks: [Data("<html>Log in</html>".utf8)]) }
        await #expect(throws: HermesAPIError.invalidResponse) { try await makeSidecar().status() }
    }

    @Test("a sidecar image is an authenticated GET to {sidecar}/media/{sha256} with its content type")
    func sidecarMedia() async throws {
        let digest = String(repeating: "A", count: 64)
        MockURLProtocol.responder = { _ in
            MockReply(chunks: [Data([0x89, 0x50])], headers: ["Content-Type": "image/png"])
        }

        let image = try await makeSidecar().media(sha256: digest)

        #expect(image == ImageAttachment(mimeType: "image/png", data: Data([0x89, 0x50])))
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(
            request.url?.absoluteString
                == "https://hermes.example.test/sidecar/media/\(String(repeating: "a", count: 64))")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
    }

    @Test("a gone image (404), a sidecar without media (503) and an invalid digest give nil")
    func sidecarMediaUnavailable() async throws {
        let digest = String(repeating: "b", count: 64)
        for status in [400, 404, 503] {
            MockURLProtocol.responder = { _ in MockReply(status: status) }
            #expect(try await makeSidecar().media(sha256: digest) == nil)
        }

        MockURLProtocol.reset()
        #expect(try await makeSidecar().media(sha256: "../status") == nil)
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test("a rejected key, a server error, a redirect and a body that is not an image are failures")
    func sidecarMediaFailures() async throws {
        let digest = String(repeating: "c", count: 64)
        MockURLProtocol.responder = { _ in MockReply(status: 401) }
        await #expect(throws: HermesAPIError.unauthorized) { try await makeSidecar().media(sha256: digest) }

        MockURLProtocol.responder = { _ in MockReply(status: 500) }
        await #expect(throws: HermesAPIError.http(status: 500)) { try await makeSidecar().media(sha256: digest) }

        MockURLProtocol.responder = { _ in
            MockReply(status: 404, responseURL: URL(string: "https://hermes.example.test/login"))
        }
        await #expect(throws: HermesAPIError.invalidResponse) { try await makeSidecar().media(sha256: digest) }

        MockURLProtocol.responder = { _ in
            MockReply(chunks: [Data("<html>Log in</html>".utf8)], headers: ["Content-Type": "text/html"])
        }
        await #expect(throws: HermesAPIError.invalidResponse) { try await makeSidecar().media(sha256: digest) }
    }
}
