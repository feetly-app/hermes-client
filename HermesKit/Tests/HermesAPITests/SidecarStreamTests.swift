import Foundation
import Testing

@testable import HermesAPI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A scripted reply for `StreamsURLProtocol`.
struct StreamsReply: Sendable {
    var status = 200
    var body = Data()
    var contentType = "application/json"
}

/// Intercepts the requests of the sidecar stream suite only, with its own state, so that it does not race
/// with the other suites' URL protocols.
final class StreamsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> StreamsReply)?
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
        let reply = Self.responder?(request) ?? StreamsReply(status: 500)
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": reply.contentType]
              )
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

@Suite("SidecarClient streams", .serialized)
struct SidecarStreamTests {
    private static let sessionID = "20261120_093000_a1b2c3"

    /// A turn as the sidecar replays it: buffered events, a keepalive, then `done`. Events after `done` are
    /// never read.
    private static let turn = Data(
        """
        event: run.started
        data: {"session_id":"20261120_093000_a1b2c3","seq":1}

        event: tool.started
        data: {"tool_name":"search","preview":"hermes","seq":2}

        event: tool.completed
        data: {"tool_name":"search","preview":"3 results","seq":3}

        event: assistant.delta
        data: {"delta":"Hel","seq":4}

        : keepalive

        event: assistant.delta
        data: {"delta":"lo","seq":5}

        event: assistant.completed
        data: {"content":"Hello","seq":6}

        event: done
        data: {}

        event: assistant.delta
        data: {"delta":"never","seq":7}


        """.utf8
    )

    private static let turnEvents: [SessionChatEvent] = [
        .toolStarted(name: "search", preview: "hermes", arguments: nil),
        .toolFinished(name: "search", preview: "3 results", failed: false),
        .delta("Hel"),
        .delta("lo"),
        .completed("Hello"),
    ]

    init() {
        StreamsURLProtocol.reset()
    }

    private func makeSidecar() -> SidecarClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamsURLProtocol.self]
        let base = URL(string: "https://hermes.example.test/sidecar") ?? URL(filePath: "/")
        return SidecarClient(
            configuration: HermesClientConfiguration(baseURL: base, apiKey: "test-key-123"),
            session: URLSession(configuration: config)
        )
    }

    private func collect(_ stream: AsyncThrowingStream<SessionChatEvent, any Error>) async throws -> [SessionChatEvent] {
        var events: [SessionChatEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func onlyRequest() throws -> URLRequest {
        #expect(StreamsURLProtocol.requests.count == 1)
        return try #require(StreamsURLProtocol.requests.first)
    }

    // MARK: Paths

    @Test("stream paths are under /sessions/{id}")
    func paths() {
        #expect(SidecarPaths.sessionChatStream("abc") == "/sessions/abc/chat/stream")
        #expect(SidecarPaths.sessionStream("abc") == "/sessions/abc/stream")
        #expect(SidecarPaths.sessionStreamStatus("abc") == "/sessions/abc/stream/status")
    }

    // MARK: Status

    @Test("status is an authenticated GET to {sidecar}/sessions/{id}/stream/status that decodes an active turn")
    func activeStatus() async throws {
        StreamsURLProtocol.responder = { _ in
            StreamsReply(
                body: Data(#"{"is_active":true,"message_id":"msg_1","started_at":"2026-11-20T09:30:00Z"}"#.utf8)
            )
        }

        let status = try await makeSidecar().activeStreamStatus(sessionID: Self.sessionID)

        let request = try onlyRequest()
        #expect(request.httpMethod == "GET")
        #expect(
            request.url?.absoluteString
                == "https://hermes.example.test/sidecar/sessions/20261120_093000_a1b2c3/stream/status"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(status == SidecarStreamStatus(isActive: true, messageID: "msg_1", startedAt: "2026-11-20T09:30:00Z"))
    }

    @Test("an idle session reports no turn, with null fields")
    func idleStatus() async throws {
        StreamsURLProtocol.responder = { _ in
            StreamsReply(body: Data(#"{"is_active":false,"message_id":null,"started_at":null}"#.utf8))
        }

        let status = try await makeSidecar().activeStreamStatus(sessionID: Self.sessionID)

        #expect(status == SidecarStreamStatus(isActive: false))
    }

    @Test("status failures map to HermesAPIError")
    func statusFailures() async throws {
        StreamsURLProtocol.responder = { _ in StreamsReply(status: 401) }
        await #expect(throws: HermesAPIError.unauthorized) {
            try await makeSidecar().activeStreamStatus(sessionID: Self.sessionID)
        }

        StreamsURLProtocol.responder = { _ in StreamsReply(body: Data("not json".utf8)) }
        await #expect(throws: HermesAPIError.invalidResponse) {
            try await makeSidecar().activeStreamStatus(sessionID: Self.sessionID)
        }

        await #expect(throws: HermesAPIError.invalidResponse) {
            try await makeSidecar().activeStreamStatus(sessionID: "a/b")
        }
    }

    // MARK: Send

    @Test("sending is a POST to {sidecar}/sessions/{id}/chat/stream with Hermes's body, streaming the events until done")
    func streamChat() async throws {
        StreamsURLProtocol.responder = { _ in StreamsReply(body: Self.turn, contentType: "text/event-stream") }
        let image = try #require(ImageAttachment(mimeType: "image/png", data: Data([0x89, 0x50])))

        let events = try await collect(
            makeSidecar().streamChat(sessionID: Self.sessionID, message: "Hi", images: [image])
        )

        let request = try onlyRequest()
        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString == "https://hermes.example.test/sidecar/sessions/20261120_093000_a1b2c3/chat/stream"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(
            try JSONSerialization.jsonObject(with: StreamsURLProtocol.bodies.first ?? Data()) as? [String: Any]
        )
        let parts = try #require(body["message"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "image_url"])
        #expect(events == Self.turnEvents)
    }

    @Test("a refused send finishes the stream with the HermesAPIError")
    func streamChatFailure() async throws {
        StreamsURLProtocol.responder = { _ in StreamsReply(status: 502) }

        await #expect(throws: HermesAPIError.http(status: 502)) {
            _ = try await collect(makeSidecar().streamChat(sessionID: Self.sessionID, message: "Hi", images: []))
        }
    }

    // MARK: Attach

    @Test("attaching is a GET to {sidecar}/sessions/{id}/stream that replays the buffered events, then ends on done")
    func attach() async throws {
        StreamsURLProtocol.responder = { _ in StreamsReply(body: Self.turn, contentType: "text/event-stream") }

        let events = try await collect(makeSidecar().attachStream(sessionID: Self.sessionID))

        let request = try onlyRequest()
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://hermes.example.test/sidecar/sessions/20261120_093000_a1b2c3/stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(events == Self.turnEvents)
    }

    @Test("attaching to a session with no turn fails with notFound; an id with a slash is never sent")
    func attachFailures() async throws {
        StreamsURLProtocol.responder = { _ in StreamsReply(status: 404) }
        await #expect(throws: HermesAPIError.notFound) {
            _ = try await collect(makeSidecar().attachStream(sessionID: Self.sessionID))
        }

        StreamsURLProtocol.reset()
        await #expect(throws: HermesAPIError.invalidResponse) {
            _ = try await collect(makeSidecar().attachStream(sessionID: "a/b"))
        }
        #expect(StreamsURLProtocol.requests.isEmpty)
    }
}
