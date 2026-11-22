import Foundation
import Testing

@testable import HermesAPI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("SessionEventParser")
struct SessionEventParserTests {
    private func frames(_ text: String, splitInto chunkSize: Int? = nil) -> [SessionEventFrame] {
        var parser = SessionEventParser()
        let bytes = Array(text.utf8)
        var result: [SessionEventFrame] = []
        if let chunkSize {
            var index = 0
            while index < bytes.count {
                let end = min(index + chunkSize, bytes.count)
                result += parser.feed(bytes[index..<end])
                index = end
            }
        } else {
            result = parser.feed(bytes)
        }
        return result + parser.finish()
    }

    @Test("a named event is a frame with its name and data")
    func namedEvent() {
        let result = frames("event: assistant.delta\ndata: {\"delta\":\"Hi\"}\n\n")

        #expect(result == [SessionEventFrame(name: "assistant.delta", data: "{\"delta\":\"Hi\"}")])
    }

    @Test("an event without an event field is named message")
    func unnamedEvent() {
        let result = frames("data: hello\n\n")

        #expect(result == [SessionEventFrame(name: "message", data: "hello")])
    }

    @Test("comments and blank data do not produce frames; several data lines are joined")
    func commentsAndMultilineData() {
        let result = frames(": keepalive\n\nevent: x\ndata: a\ndata: b\n\n")

        #expect(result == [SessionEventFrame(name: "x", data: "a\nb")])
    }

    @Test("CRLF line endings are accepted")
    func crlf() {
        let result = frames("event: done\r\ndata: {}\r\n\r\n")

        #expect(result == [SessionEventFrame(name: "done", data: "{}")])
    }

    @Test("a frame split between chunks is still parsed")
    func splitChunks() {
        let text = "event: assistant.delta\ndata: {\"delta\":\"Hi\"}\n\nevent: done\ndata: {}\n\n"

        #expect(frames(text, splitInto: 1) == frames(text))
        #expect(frames(text, splitInto: 1).count == 2)
    }

    @Test("an unterminated last frame is emitted when the input ends")
    func unterminatedEnd() {
        let result = frames("event: done\ndata: {}")

        #expect(result == [SessionEventFrame(name: "done", data: "{}")])
    }

    @Test("events map to transcript events; unknown ones are ignored")
    func decodesEvents() {
        #expect(SessionChatEvent(SessionEventFrame(name: "assistant.delta", data: "{\"delta\":\"Hi\"}")) == .delta("Hi"))
        #expect(SessionChatEvent(SessionEventFrame(name: "assistant.delta", data: "{\"delta\":\"\"}")) == nil)
        #expect(SessionChatEvent(SessionEventFrame(name: "assistant.completed", data: "{\"content\":\"Yo\"}")) == .completed("Yo"))
        #expect(SessionChatEvent(SessionEventFrame(name: "error", data: "{\"message\":\"boom\"}")) == .failed("boom"))
        #expect(SessionChatEvent(SessionEventFrame(name: "run.failed", data: "{}")) == .failed("The agent failed to reply."))
        #expect(SessionChatEvent(SessionEventFrame(name: "done", data: "{}")) == .finished)
        #expect(SessionChatEvent(SessionEventFrame(name: "tool.started", data: "{}")) == nil)
        #expect(SessionChatEvent(SessionEventFrame(name: "run.started", data: "{}")) == nil)
    }

    @Test("tool and reasoning events carry the tool name, its preview and its arguments")
    func decodesToolEvents() {
        let started = SessionEventFrame(
            name: "tool.started", data: #"{"tool_name":"terminal","preview":"ls -la","args":{"command":"ls -la"}}"#
        )
        #expect(
            SessionChatEvent(started)
                == .toolStarted(name: "terminal", preview: "ls -la", arguments: #"{"command":"ls -la"}"#)
        )
        let completed = SessionEventFrame(name: "tool.completed", data: #"{"tool_name":"terminal","preview":"ok"}"#)
        #expect(SessionChatEvent(completed) == .toolFinished(name: "terminal", preview: "ok", failed: false))
        let failed = SessionEventFrame(name: "tool.failed", data: #"{"tool_name":"terminal","preview":null}"#)
        #expect(SessionChatEvent(failed) == .toolFinished(name: "terminal", preview: nil, failed: true))
        let thinking = SessionEventFrame(name: "tool.progress", data: #"{"tool_name":"_thinking","delta":"Hmm"}"#)
        #expect(SessionChatEvent(thinking) == .thinking("Hmm"))
        // Progress of a real tool is not shown.
        let progress = SessionEventFrame(name: "tool.progress", data: #"{"tool_name":"terminal","delta":"…"}"#)
        #expect(SessionChatEvent(progress) == nil)
    }
}

extension HermesAPISessionsTests {
    private func chatFixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "session_chat", withExtension: "sse"))
        return try Data(contentsOf: url)
    }

    @Test("the chat stream is an authenticated POST with the message as JSON, to /api/sessions/{id}/chat/stream")
    func chatRequestShape() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! chatFixture()) }

        for try await _ in makeClient().streamSessionChat(sessionID: "20261120_093000_a1b2c3", message: "Hi") {}

        let request = try #require(SessionsURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://hermes.example.test/api/sessions/20261120_093000_a1b2c3/chat/stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(
            try JSONSerialization.jsonObject(with: SessionsURLProtocol.bodies.first ?? Data()) as? [String: Any]
        )
        #expect(body["message"] as? String == "Hi")
        #expect(body.count == 1)
    }

    @Test("the reply events are yielded in order and the stream ends at done")
    func chatEvents() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! chatFixture()) }

        var events: [SessionChatEvent] = []
        for try await event in makeClient().streamSessionChat(sessionID: "s", message: "Hi") {
            events.append(event)
        }

        #expect(
            events == [.delta("Hel"), .delta("lo"), .toolStarted(name: "search", preview: nil, arguments: nil), .completed("Hello")]
        )
    }

    @Test("a session id with a slash is rejected before any request is sent")
    func chatRejectsSlash() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! chatFixture()) }

        await #expect(throws: HermesAPIError.invalidResponse) {
            for try await _ in makeClient().streamSessionChat(sessionID: "a/b", message: "Hi") {}
        }
        #expect(SessionsURLProtocol.requests.isEmpty)
    }

    @Test("a rejected chat request maps to its status error")
    func chatStatusError() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(status: 429) }

        await #expect(throws: HermesAPIError.http(status: 429)) {
            for try await _ in makeClient().streamSessionChat(sessionID: "s", message: "Hi") {}
        }
    }

    @Test("images go in the message as image_url parts after the text")
    func chatSendsImages() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! chatFixture()) }
        let image = try #require(ImageAttachment(mimeType: "image/png", data: Data("abc".utf8)))

        for try await _ in makeClient().streamSessionChat(sessionID: "s", message: "Look", images: [image]) {}

        let body = try #require(
            try JSONSerialization.jsonObject(with: SessionsURLProtocol.bodies.first ?? Data()) as? [String: Any]
        )
        let parts = try #require(body["message"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "image_url"])
    }

    @Test("tool events are yielded and progress of a tool is skipped without breaking the stream")
    func toolEventsAreYielded() async throws {
        let stream = """
        event: tool.started
        data: {"tool_name":"terminal","preview":"ls"}

        event: tool.progress
        data: {"delta":"thinking"}

        event: assistant.delta
        data: {"delta":"Done"}

        event: done
        data: {}


        """
        SessionsURLProtocol.responder = { _ in SessionsReply(body: Data(stream.utf8)) }

        var events: [SessionChatEvent] = []
        for try await event in makeClient().streamSessionChat(sessionID: "s", message: "Hi") {
            events.append(event)
        }

        #expect(events == [.toolStarted(name: "terminal", preview: "ls", arguments: nil), .delta("Done")])
    }
}
