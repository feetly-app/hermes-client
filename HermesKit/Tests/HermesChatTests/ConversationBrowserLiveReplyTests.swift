import Foundation
import HermesAPI
import Testing

@testable import HermesChat

/// Streams one delta for each message, then stays open until the consumer cancels.
actor HangingChatStreamSource: SessionListing {
    private(set) var listedFor: [String] = []
    private(set) var deleted: [String] = []

    func forkSession(sessionID: String) async throws -> RemoteSession {
        throw HermesAPIError.notFound
    }

    func listSessions(limit: Int, offset: Int) async throws -> SessionPage {
        SessionPage(sessions: [], hasMore: false)
    }

    func listSessionMessages(sessionID: String, limit: Int, offset: Int) async throws -> SessionMessagesPage {
        listedFor.append(sessionID)
        return SessionMessagesPage(sessionID: sessionID, messages: [], hasMore: false)
    }

    func streamSessionChat(
        sessionID: String, message: String, images: [ImageAttachment]
    ) -> AsyncThrowingStream<SessionChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.delta("Hel"))
                try? await Task.sleep(for: .seconds(30))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func deleteSession(sessionID: String) async throws {
        deleted.append(sessionID)
    }
}

@MainActor
@Suite("ConversationBrowser live replies")
struct ConversationBrowserLiveReplyTests {
    private func makeBrowser(source: any SessionListing) -> ConversationBrowser {
        ConversationBrowser(remoteSessions: RemoteSessionList(source: source), model: ModelChoice(model: "m"))
    }

    @Test("a session left while its reply streams opens again on the same transcript, not reloaded")
    func reopenStreaming() async throws {
        let source = HangingChatStreamSource()
        let browser = makeBrowser(source: source)
        let remote = RemoteSession(id: "api-1", source: "api_server")
        browser.openRemote(remote)
        let transcript = try #require(browser.openedRemote)
        await transcript.load()
        let send = Task { await transcript.send("Hi") }
        await waitUntil { transcript.lines.last?.text == "Hel" }

        browser.selectSession(nil)
        browser.openRemote(remote)

        #expect(browser.openedRemote === transcript)
        #expect(transcript.isSending)
        #expect(transcript.lines.map(\.text) == ["Hi", "Hel"])
        #expect(await source.listedFor == ["api-1"])
        transcript.stop()
        await send.value
    }

    @Test("a session left while its reply streams keeps its transcript across another session")
    func reopenStreamingAfterAnother() async throws {
        let source = HangingChatStreamSource()
        let browser = makeBrowser(source: source)
        let remote = RemoteSession(id: "api-1", source: "api_server")
        browser.openRemote(remote)
        let transcript = try #require(browser.openedRemote)
        await transcript.load()
        let send = Task { await transcript.send("Hi") }
        await waitUntil { transcript.lines.last?.text == "Hel" }

        browser.openRemote(RemoteSession(id: "api-2", source: "api_server"))
        browser.openRemote(remote)

        #expect(browser.openedRemote === transcript)
        transcript.stop()
        await send.value
    }

    @Test("a session whose reply ended opens on a new transcript")
    func reopenFinished() async throws {
        let source = FakeChatStreamSource(events: [.completed("Hello")])
        let browser = makeBrowser(source: source)
        let remote = RemoteSession(id: "api-1", source: "api_server")
        browser.openRemote(remote)
        let transcript = try #require(browser.openedRemote)
        await transcript.send("Hi")

        browser.selectSession(nil)
        browser.openRemote(remote)

        #expect(browser.openedRemote !== transcript)
    }

    @Test("deleting a session left while its reply streams stops the reply")
    func deleteStopsKeptReply() async throws {
        let source = HangingChatStreamSource()
        let browser = makeBrowser(source: source)
        browser.openRemote(RemoteSession(id: "api-1", source: "api_server"))
        let transcript = try #require(browser.openedRemote)
        await transcript.load()
        let send = Task { await transcript.send("Hi") }
        await waitUntil { transcript.lines.last?.text == "Hel" }
        browser.selectSession(nil)

        try await browser.deleteSession("api-1")
        await send.value

        #expect(!transcript.isSending)
        #expect(await source.deleted == ["api-1"])
    }
}
