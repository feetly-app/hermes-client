import Foundation
import HermesAPI
import Testing

@testable import HermesChat

/// Streams a scripted reply, optionally failing, and records the messages it was sent, the sessions
/// they were sent to, and the forks it was asked for.
actor FakeChatStreamSource: SessionListing {
    private let events: [SessionChatEvent]
    private let failure: HermesAPIError?
    private let forkResult: Result<RemoteSession, HermesAPIError>
    private(set) var sent: [String] = []
    private(set) var sentImages: [[ImageAttachment]] = []
    private(set) var sentTo: [String] = []
    private(set) var forked: [String] = []
    private(set) var listedFor: [String] = []

    init(
        events: [SessionChatEvent],
        failure: HermesAPIError? = nil,
        forkResult: Result<RemoteSession, HermesAPIError> = .failure(.notFound)
    ) {
        self.events = events
        self.failure = failure
        self.forkResult = forkResult
    }

    func forkSession(sessionID: String) async throws -> RemoteSession {
        forked.append(sessionID)
        return try forkResult.get()
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
        sent.append(message)
        sentImages.append(images)
        sentTo.append(sessionID)
        let events = events
        let failure = failure
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

@MainActor
@Suite("RemoteTranscript.send")
struct RemoteTranscriptSendTests {
    @Test("the user line appears, then the reply grows with each delta")
    func streamsReply() async {
        let source = FakeChatStreamSource(events: [
            .delta("Hel"), .delta("lo"), .completed("Hello"), .finished,
        ])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.send("  Hi  ")

        #expect(transcript.lines.map(\.role) == ["user", "assistant"])
        #expect(transcript.lines.map(\.text) == ["Hi", "Hello"])
        #expect(!transcript.isSending)
        #expect(transcript.sendError == nil)
        #expect(await source.sent == ["Hi"])
    }

    @Test("a completed event without deltas sets the reply")
    func completedOnly() async {
        let source = FakeChatStreamSource(events: [.completed("Whole reply")])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.send("Hi")

        #expect(transcript.lines.last?.text == "Whole reply")
    }

    @Test("blank text is not sent")
    func blankIgnored() async {
        let source = FakeChatStreamSource(events: [.completed("x")])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.send("   \n ")

        #expect(transcript.lines.isEmpty)
        #expect(await source.sent.isEmpty)
    }

    @Test("a run failure is reported and an empty reply is removed")
    func runFailure() async {
        let source = FakeChatStreamSource(events: [.failed("The model is unavailable.")])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.send("Hi")

        #expect(transcript.sendError == "The model is unavailable.")
        #expect(transcript.lines.map(\.role) == ["user"])
    }

    @Test("a transport failure keeps the partial reply and reports the error")
    func transportFailure() async {
        let source = FakeChatStreamSource(events: [.delta("Par")], failure: .timeout)
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.send("Hi")

        #expect(transcript.lines.last?.text == "Par")
        #expect(transcript.sendError == HermesAPIError.timeout.errorDescription)
        #expect(!transcript.isSending)
    }

    @Test("a session that accepts API messages is not forked")
    func noForkForAPISession() async {
        let source = FakeChatStreamSource(events: [.completed("Hello")])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.send("Hi")

        #expect(await source.forked.isEmpty)
        #expect(await source.sentTo == ["s1"])
        #expect(transcript.activeSessionID == "s1")
    }

    @Test("a session created elsewhere is forked once, then messages and pages go to the fork")
    func forksBeforeFirstMessage() async {
        let fork = RemoteSession(id: "api_fork", title: "Dashboard chat #2", source: "api_server")
        let source = FakeChatStreamSource(events: [.completed("Hello")], forkResult: .success(fork))
        let transcript = RemoteTranscript(sessionID: "local-1", title: "Dashboard chat", source: source, acceptsMessages: false)
        var reported: [RemoteSession] = []
        transcript.onFork = { reported.append($0) }

        await transcript.send("Hi")
        await transcript.send("Again")
        await transcript.load()

        #expect(await source.forked == ["local-1"])
        #expect(await source.sentTo == ["api_fork", "api_fork"])
        #expect(await source.listedFor == ["api_fork"])
        #expect(reported == [fork])
        #expect(transcript.sessionID == "local-1")
        #expect(transcript.activeSessionID == "api_fork")
        #expect(transcript.acceptsMessages)
        #expect(transcript.sendError == nil)
    }

    @Test("a failed fork sends nothing, keeps the user line and reports the error")
    func failedFork() async {
        let source = FakeChatStreamSource(events: [.completed("Hello")], forkResult: .failure(.http(status: 500)))
        let transcript = RemoteTranscript(sessionID: "local-1", title: nil, source: source, acceptsMessages: false)

        await transcript.send("Hi")

        #expect(await source.sent.isEmpty)
        #expect(transcript.lines.map(\.role) == ["user"])
        #expect(transcript.activeSessionID == "local-1")
        #expect(!transcript.acceptsMessages)
        #expect(transcript.sendError?.contains("started outside the app") == true)
        #expect(!transcript.isSending)
    }

    @Test("images go with the message and show on the user line")
    func sendsImages() async throws {
        let source = FakeChatStreamSource(events: [.completed("A cat."), .finished])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)
        let image = try #require(ImageAttachment(mimeType: "image/jpeg", data: Data([1])))

        await transcript.send("What is this?", images: [image])

        #expect(await source.sentImages == [[image]])
        #expect(transcript.lines.first?.images == [.attached(image)])
        #expect(transcript.lines.map(\.text) == ["What is this?", "A cat."])
    }

    @Test("a message with images and no text is sent; images past the limit are dropped")
    func imagesWithoutText() async throws {
        let source = FakeChatStreamSource(events: [.completed("Five photos."), .finished])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)
        let images = try (1...5).map { try #require(ImageAttachment(mimeType: "image/png", data: Data([UInt8($0)]))) }

        await transcript.send("  ", images: images)

        #expect(await source.sent == [""])
        #expect(await source.sentImages.first?.count == RemoteTranscript.maxImagesPerMessage)
        #expect(transcript.hasSent)
    }

    @Test("the end of a reply is reported, after a failure too")
    func replyEndedIsReported() async {
        let transcript = RemoteTranscript(
            sessionID: "s1", title: nil, source: FakeChatStreamSource(events: [], failure: .http(status: 500)))
        var ended = 0
        transcript.onReplyEnded = { ended += 1 }

        await transcript.send("Hi")

        #expect(ended == 1)
        #expect(transcript.sendError != nil)
    }
}
