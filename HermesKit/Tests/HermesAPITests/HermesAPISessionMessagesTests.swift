import Foundation
import Testing

@testable import HermesAPI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension HermesAPISessionsTests {
    private func messagesFixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "session_messages", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test("messages are a GET to /api/sessions/{id}/messages, newest first, with limit and offset")
    func messagesRequestShape() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! messagesFixture()) }

        _ = try await makeClient().listSessionMessages(sessionID: "20261120_093000_a1b2c3", limit: 20, offset: 40)

        let request = try #require(SessionsURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(
            request.url?.absoluteString
                == "https://hermes.example.test/api/sessions/20261120_093000_a1b2c3/messages?limit=20&offset=40&order=latest"
        )
    }

    @Test("the message limit is clamped to 1...500")
    func messagesLimitClamped() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! messagesFixture()) }
        let client = makeClient()

        _ = try await client.listSessionMessages(sessionID: "s", limit: 0)
        _ = try await client.listSessionMessages(sessionID: "s", limit: 9_000)

        let limits = SessionsURLProtocol.requests.compactMap {
            URLComponents(url: $0.url ?? baseURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "limit" }?.value
        }
        #expect(limits == ["1", "500"])
    }

    @Test("the page decodes messages in order, with integer ids, nil content and tool rows")
    func decodesMessages() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! messagesFixture()) }

        let page = try await makeClient().listSessionMessages(sessionID: "20261120_093000_a1b2c3")

        #expect(page.sessionID == "20261120_093000_a1b2c3")
        #expect(page.messages.map(\.id) == ["1", "2", "3", "4"])
        #expect(page.messages.map(\.role) == ["user", "assistant", "tool", "assistant"])
        #expect(page.messages[0].content == "Can you draft the release notes?")
        #expect(page.messages[1].content == nil)
        #expect(page.messages[3].timestamp == Date(timeIntervalSince1970: 1_795_157_420.5))
        #expect(!page.hasMore)
    }

    @Test("display_content and the known display_metadata fields are decoded; an unknown shape is ignored")
    func decodesDisplayFields() async throws {
        let rows = [
            #"{"id":1,"role":"user","content":"[wrapped]","display_content":"Hi","display_kind":"steer"}"#,
            #"{"id":2,"role":"user","content":"[ASYNC]","display_kind":"async_delegation_complete","display_metadata":{"delegation_id":"d","task_count":2,"failed_count":0,"display_text":"Done"}}"#,
            #"{"id":3,"role":"user","content":"x","display_metadata":"not an object"}"#,
        ].joined(separator: ",")
        SessionsURLProtocol.responder = { _ in
            SessionsReply(body: Data(#"{"data":[\#(rows)],"pagination":{"returned":3}}"#.utf8))
        }

        let messages = try await makeClient().listSessionMessages(sessionID: "s").messages

        #expect(messages.map(\.displayContent) == ["Hi", nil, nil])
        #expect(messages[1].displayMetadata == DisplayMetadata(displayText: "Done", taskCount: 2, failedCount: 0))
        #expect(messages[2].displayMetadata == nil)
    }

    @Test("a full page reports hasMore, so the next page can be asked for")
    func fullPageHasMore() async throws {
        let rows = (1...2).map { #"{"id":\#($0),"role":"user","content":"m\#($0)"}"# }.joined(separator: ",")
        SessionsURLProtocol.responder = { _ in
            SessionsReply(body: Data(#"{"data":[\#(rows)],"pagination":{"returned":2}}"#.utf8))
        }

        let page = try await makeClient().listSessionMessages(sessionID: "s", limit: 2)

        #expect(page.hasMore)
    }

    @Test("a session id with a slash is rejected before any request is sent")
    func rejectsSlashInID() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(body: try! messagesFixture()) }

        await #expect(throws: HermesAPIError.invalidResponse) {
            try await makeClient().listSessionMessages(sessionID: "a/b")
        }
        #expect(SessionsURLProtocol.requests.isEmpty)
    }

    @Test("an unknown session is a notFound error")
    func unknownSession() async throws {
        SessionsURLProtocol.responder = { _ in SessionsReply(status: 404) }

        await #expect(throws: HermesAPIError.notFound) {
            try await makeClient().listSessionMessages(sessionID: "gone")
        }
    }

    @Test("a message stored as parts keeps its text")
    func decodesMultimodalContent() async throws {
        SessionsURLProtocol.responder = { _ in
            SessionsReply(body: Data(#"""
            {"object":"list","session_id":"s","data":[
              {"id":1,"role":"user","content":[{"type":"text","text":"What is this?"},
                {"type":"image_url","image_url":{"url":"data:image/png;base64,YWJj"}},{"type":"input_image"}]},
              {"id":2,"role":"user","content":{"unexpected":true}}
            ],"pagination":{"limit":200,"offset":0,"returned":2}}
            """#.utf8))
        }

        let page = try await makeClient().listSessionMessages(sessionID: "s")

        #expect(page.messages[0].content == "What is this?")
        #expect(page.messages[1].content == nil)
    }
}
