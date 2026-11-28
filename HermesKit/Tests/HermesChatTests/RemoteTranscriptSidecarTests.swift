import Foundation
import HermesAPI
import Testing

@testable import HermesChat

/// A sidecar that runs turns in the background: answers each message with a scripted reply, reports a turn
/// running or not, and replays a scripted turn to whoever attaches. Records the calls it receives.
actor FakeTurnStreamer: TurnStreaming {
    private let status: Result<SidecarStreamStatus, HermesAPIError>
    private let replyEvents: [SessionChatEvent]
    private let attachEvents: [SessionChatEvent]
    /// Set to keep the attached stream open after its events, until the consumer leaves.
    private let attachStaysOpen: Bool
    private(set) var sent: [String] = []
    private(set) var sentImages: [[ImageAttachment]] = []
    private(set) var sentTo: [String] = []
    private(set) var statusRequests: [String] = []
    private(set) var attached: [String] = []

    init(
        status: Result<SidecarStreamStatus, HermesAPIError> = .success(SidecarStreamStatus(isActive: false)),
        replyEvents: [SessionChatEvent] = [.completed("Sidecar reply")],
        attachEvents: [SessionChatEvent] = [],
        attachStaysOpen: Bool = false
    ) {
        self.status = status
        self.replyEvents = replyEvents
        self.attachEvents = attachEvents
        self.attachStaysOpen = attachStaysOpen
    }

    func activeStreamStatus(sessionID: String) async throws -> SidecarStreamStatus {
        statusRequests.append(sessionID)
        return try status.get()
    }

    func streamChat(
        sessionID: String, message: String, images: [ImageAttachment]
    ) -> AsyncThrowingStream<SessionChatEvent, any Error> {
        sent.append(message)
        sentImages.append(images)
        sentTo.append(sessionID)
        return Self.stream(replyEvents, staysOpen: false)
    }

    func attachStream(sessionID: String) -> AsyncThrowingStream<SessionChatEvent, any Error> {
        attached.append(sessionID)
        return Self.stream(attachEvents, staysOpen: attachStaysOpen)
    }

    private static func stream(
        _ events: [SessionChatEvent], staysOpen: Bool
    ) -> AsyncThrowingStream<SessionChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    continuation.yield(event)
                }
                if staysOpen {
                    try? await Task.sleep(for: .seconds(30))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Returns one stored page: the user message of the turn still running, with no reply yet.
actor RunningTurnSource: SessionListing {
    private(set) var sent: [String] = []

    func forkSession(sessionID: String) async throws -> RemoteSession {
        throw HermesAPIError.notFound
    }

    func listSessions(limit: Int, offset: Int) async throws -> SessionPage {
        SessionPage(sessions: [RemoteSession(id: "s1", source: "api_server")], hasMore: false)
    }

    func listSessionMessages(sessionID: String, limit: Int, offset: Int) async throws -> SessionMessagesPage {
        SessionMessagesPage(
            sessionID: sessionID,
            messages: [SessionMessage(id: "m1", role: "user", content: "Run the tests")],
            hasMore: false
        )
    }

    func streamSessionChat(
        sessionID: String, message: String, images: [ImageAttachment]
    ) -> AsyncThrowingStream<SessionChatEvent, any Error> {
        sent.append(message)
        return AsyncThrowingStream { $0.finish() }
    }
}

/// Waits until the reply of a turn attached to by `load()` ended. Gives up after 5 seconds.
@MainActor
func waitUntilAttachEnds(_ transcript: RemoteTranscript) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while let task = transcript.attachTask, ContinuousClock.now < deadline {
        await task.value
    }
}

@MainActor
@Suite("RemoteTranscript with a sidecar")
struct RemoteTranscriptSidecarTests {
    private static let running = SidecarStreamStatus(
        isActive: true, messageID: "msg_1", startedAt: "2026-11-20T09:30:00Z"
    )

    private static let turn: [SessionChatEvent] = [
        .thinking("Looking at the suite"),
        .toolStarted(name: "terminal", preview: "swift test", arguments: #"{"command":"swift test"}"#),
        .toolFinished(name: "terminal", preview: "All tests passed", failed: false),
        .delta("All "),
        .delta("green"),
        .completed("All green."),
    ]

    // MARK: Sending

    @Test("with a sidecar, a message goes through the sidecar, not to the instance")
    func sendsThroughSidecar() async throws {
        let source = FakeChatStreamSource(events: [.completed("Direct reply")])
        let sidecar = FakeTurnStreamer(replyEvents: [.delta("Side"), .completed("Sidecar reply")])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source, sidecar: sidecar)
        let image = try #require(ImageAttachment(mimeType: "image/png", data: Data([1, 2])))

        await transcript.send("Hi", images: [image])

        #expect(await sidecar.sent == ["Hi"])
        #expect(await sidecar.sentTo == ["s1"])
        #expect(await sidecar.sentImages == [[image]])
        #expect(await source.sent.isEmpty)
        #expect(transcript.lines.map(\.text) == ["Hi", "Sidecar reply"])
        #expect(!transcript.isSending)
    }

    @Test("without a sidecar, a message goes to the instance directly")
    func sendsDirectlyWithoutSidecar() async {
        let source = FakeChatStreamSource(events: [.completed("Direct reply")])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.send("Hi")

        #expect(await source.sent == ["Hi"])
        #expect(transcript.lines.map(\.text) == ["Hi", "Direct reply"])
    }

    @Test("a session created elsewhere is forked on the instance, then the message goes to the fork via the sidecar")
    func forkThenSidecar() async {
        let fork = RemoteSession(id: "s1-fork", source: "api_server")
        let source = FakeChatStreamSource(events: [], forkResult: .success(fork))
        let sidecar = FakeTurnStreamer()
        let transcript = RemoteTranscript(
            sessionID: "s1", title: nil, source: source, acceptsMessages: false, sidecar: sidecar
        )

        await transcript.send("Hi")

        #expect(await source.forked == ["s1"])
        #expect(await sidecar.sentTo == ["s1-fork"])
        #expect(await source.sent.isEmpty)
    }

    // MARK: Attaching

    @Test("opening a session with a running turn attaches and shows the buffered reply and its steps")
    func attachesToRunningTurn() async throws {
        let sidecar = FakeTurnStreamer(status: .success(Self.running), attachEvents: Self.turn)
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: RunningTurnSource(), sidecar: sidecar)
        var ended = 0
        transcript.onReplyEnded = { ended += 1 }

        await transcript.load()
        #expect(transcript.state == .loaded)
        await waitUntilAttachEnds(transcript)

        #expect(await sidecar.statusRequests == ["s1"])
        #expect(await sidecar.attached == ["s1"])
        #expect(transcript.lines.map(\.role) == ["user", "assistant"])
        #expect(transcript.lines.map(\.text) == ["Run the tests", "All green."])
        let steps = try #require(transcript.lines.last?.steps)
        #expect(steps.map(\.kind) == [.thinking, .tool])
        #expect(steps.first?.result == "Looking at the suite")
        #expect(steps.last?.name == "terminal")
        #expect(steps.last?.result == "All tests passed")
        #expect(steps.last?.status == .done)
        #expect(!transcript.isSending)
        #expect(ended == 1)
    }

    @Test("while the attached turn runs the transcript is sending, and live deltas keep extending the reply")
    func liveTurnIsSending() async {
        let sidecar = FakeTurnStreamer(
            status: .success(Self.running), attachEvents: [.delta("Work"), .delta("ing")], attachStaysOpen: true
        )
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: RunningTurnSource(), sidecar: sidecar)

        await transcript.load()
        await waitUntil { transcript.lines.last?.text == "Working" }

        #expect(transcript.isSending)
        // A message is not sent while the turn runs.
        await transcript.send("Another one")
        #expect(await sidecar.sent.isEmpty)

        transcript.stop()
        await waitUntilAttachEnds(transcript)
        #expect(!transcript.isSending)
        #expect(transcript.lines.last?.text == "Working")
    }

    @Test("a load while the attached turn runs keeps its live reply below the page")
    func reloadKeepsLiveReply() async {
        let sidecar = FakeTurnStreamer(
            status: .success(Self.running), attachEvents: [.delta("Work")], attachStaysOpen: true
        )
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: RunningTurnSource(), sidecar: sidecar)
        await transcript.load()
        await waitUntil { transcript.lines.last?.text == "Work" }

        await transcript.load()

        #expect(transcript.lines.map(\.text) == ["Run the tests", "Work"])
        #expect(await sidecar.attached == ["s1"])
        transcript.stop()
        await waitUntilAttachEnds(transcript)
    }

    @Test("with no running turn, opening does not attach")
    func idleDoesNotAttach() async {
        let sidecar = FakeTurnStreamer(status: .success(SidecarStreamStatus(isActive: false)))
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: RunningTurnSource(), sidecar: sidecar)

        await transcript.load()

        #expect(await sidecar.statusRequests == ["s1"])
        #expect(await sidecar.attached.isEmpty)
        #expect(transcript.attachTask == nil)
        #expect(transcript.lines.map(\.text) == ["Run the tests"])
        #expect(!transcript.isSending)
    }

    @Test("a failed status check is not an error: the stored page shows")
    func statusFailureIgnored() async {
        let sidecar = FakeTurnStreamer(status: .failure(.notFound))
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: RunningTurnSource(), sidecar: sidecar)

        await transcript.load()

        #expect(transcript.state == .loaded)
        #expect(await sidecar.attached.isEmpty)
        #expect(transcript.lines.map(\.text) == ["Run the tests"])
    }

    @Test("an attached turn that fails reports why")
    func attachedFailure() async {
        let sidecar = FakeTurnStreamer(
            status: .success(Self.running), attachEvents: [.failed("The model is unavailable.")]
        )
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: RunningTurnSource(), sidecar: sidecar)

        await transcript.load()
        await waitUntilAttachEnds(transcript)

        #expect(transcript.sendError == "The model is unavailable.")
        #expect(transcript.lines.map(\.text) == ["Run the tests"])
    }
}

@MainActor
@Suite("ConversationBrowser with a sidecar")
struct ConversationBrowserSidecarTests {
    @Test("a conversation created in the browser sends through the sidecar")
    func createdConversationUsesSidecar() async throws {
        let instance = FakeInstance()
        let sidecar = FakeTurnStreamer()
        let browser = ConversationBrowser(
            remoteSessions: RemoteSessionList(source: instance, sidecar: sidecar), model: ModelChoice(model: "m")
        )

        let session = try await browser.createConversation()
        let transcript = try #require(browser.openedRemote)
        await transcript.send("Hi")

        #expect(await sidecar.sentTo == [session.id])
        #expect(transcript.lines.last?.text == "Sidecar reply")
    }

    @Test("without a sidecar, the browser's conversations send to the instance")
    func noSidecarSendsDirectly() async throws {
        let instance = FakeInstance()
        let browser = ConversationBrowser(remoteSessions: RemoteSessionList(source: instance), model: ModelChoice(model: "m"))

        _ = try await browser.createConversation()
        let transcript = try #require(browser.openedRemote)
        await transcript.send("Hi")

        #expect(transcript.lines.last?.text == "Reply to Hi")
    }

    @Test("opening a session whose turn runs on the sidecar attaches and hydrates the live reply")
    func openAttaches() async throws {
        let sidecar = FakeTurnStreamer(
            status: .success(SidecarStreamStatus(isActive: true)), attachEvents: [.delta("Half")], attachStaysOpen: true
        )
        let browser = ConversationBrowser(
            remoteSessions: RemoteSessionList(source: RunningTurnSource(), sidecar: sidecar), model: ModelChoice(model: "m")
        )
        await browser.reloadSessions()
        let session = try #require(browser.remoteSessions.sessions.first)

        browser.openRemote(session)
        let transcript = try #require(browser.openedRemote)
        await waitUntil { transcript.lines.last?.text == "Half" }

        #expect(transcript.lines.map(\.text) == ["Run the tests", "Half"])
        #expect(transcript.isSending)
        #expect(await sidecar.attached == ["s1"])
        transcript.stop()
        await waitUntilAttachEnds(transcript)
    }
}
