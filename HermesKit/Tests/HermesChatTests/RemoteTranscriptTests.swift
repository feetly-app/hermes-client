import Foundation
import HermesAPI
import Testing

@testable import HermesChat

/// Returns scripted message pages and records the (offset, limit) it was asked for.
actor FakeMessageSource: SessionListing {
    private var pages: [Result<SessionMessagesPage, HermesAPIError>]
    private(set) var requests: [(offset: Int, limit: Int)] = []

    init(pages: [Result<SessionMessagesPage, HermesAPIError>]) {
        self.pages = pages
    }

    func listSessions(limit: Int, offset: Int) async throws -> SessionPage {
        SessionPage(sessions: [], hasMore: false)
    }

    func listSessionMessages(sessionID: String, limit: Int, offset: Int) async throws -> SessionMessagesPage {
        requests.append((offset: offset, limit: limit))
        guard !pages.isEmpty else { return SessionMessagesPage(sessionID: sessionID, messages: [], hasMore: false) }
        return try pages.removeFirst().get()
    }

    func streamSessionChat(
        sessionID: String, message: String, images: [ImageAttachment]
    ) -> AsyncThrowingStream<SessionChatEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func forkSession(sessionID: String) async throws -> RemoteSession {
        throw HermesAPIError.notFound
    }
}

/// Holds each message request until `release()`, then answers it, or throws `CancellationError` if the
/// requesting task was cancelled meanwhile, as `URLSession` does. Once released, the gate stays open:
/// a later request is answered at once, so an unexpected extra request fails the count check instead
/// of hanging the test.
actor GatedMessageSource: SessionListing {
    private let page: SessionMessagesPage
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var requestCount = 0

    init(page: SessionMessagesPage) {
        self.page = page
    }

    var pendingCount: Int { waiting.count }

    func release() {
        isOpen = true
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume() }
    }

    func listSessions(limit: Int, offset: Int) async throws -> SessionPage {
        SessionPage(sessions: [], hasMore: false)
    }

    func listSessionMessages(sessionID: String, limit: Int, offset: Int) async throws -> SessionMessagesPage {
        requestCount += 1
        if !isOpen {
            await withCheckedContinuation { waiting.append($0) }
        }
        try Task.checkCancellation()
        return page
    }

    func streamSessionChat(
        sessionID: String, message: String, images: [ImageAttachment]
    ) -> AsyncThrowingStream<SessionChatEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func forkSession(sessionID: String) async throws -> RemoteSession {
        throw HermesAPIError.notFound
    }
}

/// Waits until the source holds a request. Gives up after 5 seconds so that a request that is never sent
/// fails the test instead of hanging it.
func waitForPendingRequest(_ source: GatedMessageSource) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while await source.pendingCount == 0, ContinuousClock.now < deadline {
        await Task.yield()
    }
}

/// Waits until the page request in flight ends, without starting one. Gives up after 5 seconds so that
/// a request that never ends fails the test instead of hanging it.
@MainActor
func waitUntilLoadEnds(_ transcript: RemoteTranscript) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while transcript.state == .loading, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
@Suite("RemoteTranscript")
struct RemoteTranscriptTests {
    private func message(
        _ id: String, _ role: String, _ content: String?, kind: String? = nil, at seconds: Double? = nil
    ) -> SessionMessage {
        SessionMessage(
            id: id,
            role: role,
            content: content,
            timestamp: seconds.map { Date(timeIntervalSince1970: $0) },
            displayKind: kind
        )
    }

    @Test("only user and assistant messages with text are kept, trimmed, in order")
    func filtersLines() {
        let lines = RemoteTranscript.lines(from: [
            message("1", "user", "  Hello  "),
            message("2", "tool", "{\"result\": 1}"),
            message("3", "system", "You are a helpful agent."),
            message("4", "assistant", "Hi!", at: 100),
            message("5", "assistant", nil),
            message("6", "assistant", "   "),
            message("7", "assistant", "Compaction summary", kind: "hidden"),
        ])

        #expect(lines.map(\.id) == ["1", "4"])
        #expect(lines.map(\.text) == ["Hello", "Hi!"])
        #expect(lines[1].date == Date(timeIntervalSince1970: 100))
        #expect(lines.map(\.role) == ["user", "assistant"])
    }

    @Test("a renamed or newly named session gives the open transcript its title")
    func updateTitle() {
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: FakeMessageSource(pages: []))

        transcript.update(from: RemoteSession(id: "other", title: "Wrong"))
        transcript.update(from: RemoteSession(id: "s1", title: ""))
        #expect(transcript.title == nil)

        transcript.update(from: RemoteSession(id: "s1", title: "Trip plans"))
        #expect(transcript.title == "Trip plans")
    }

    @Test("image markers leave the text and become stored images, named by digest when the path has one")
    func imageMarkers() {
        let digest = String(repeating: "b", count: 64)
        let content = """
            Two photos

            [Image attached at: /data/native-inputs/\(digest)/api_x.jpg]
            [Image attached: https://hermes.example.test/y.png]
            [screenshot]
            [screenshot]
            """

        let lines = RemoteTranscript.lines(from: [
            message("1", "user", content),
            message("2", "user", "[Image attached at: /data/native-inputs/\(digest)/api_y.jpg]\n[screenshot]"),
        ])

        #expect(lines.map(\.text) == ["Two photos", ""])
        #expect(lines[0].images == [.stored(sha256: digest), .stored(sha256: nil)])
        #expect(lines[1].images == [.stored(sha256: digest)])
        #expect(!lines[1].isActivity)
    }

    @Test("the transcript hands out the loader it was given, and none without a sidecar")
    func storedImagesLoader() {
        let source = FakeMessageSource(pages: [])
        let loader = StoredImageLoader(fetcher: NoImages())

        #expect(RemoteTranscript(sessionID: "s1", title: nil, source: source, storedImages: loader).storedImages === loader)
        #expect(RemoteTranscript(sessionID: "s1", title: nil, source: source).storedImages == nil)
    }

    @Test("load asks for the first page, newest messages, and keeps hasMore")
    func loadFirstPage() async {
        let source = FakeMessageSource(pages: [
            .success(SessionMessagesPage(
                sessionID: "s1",
                messages: [message("1", "user", "Hi")],
                hasMore: true
            )),
        ])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.load()

        #expect(transcript.lines.map(\.text) == ["Hi"])
        #expect(transcript.hasMore)
        #expect(transcript.state == .loaded)
        #expect(await source.requests.map(\.offset) == [0])
        #expect(await source.requests.map(\.limit) == [RemoteTranscript.pageSize])
    }

    @Test("the next offset counts every received message, including the ones not displayed")
    func loadMoreOffsetCountsHiddenRows() async {
        let source = FakeMessageSource(pages: [
            .success(SessionMessagesPage(
                sessionID: "s1",
                messages: [message("1", "tool", "x"), message("2", "user", "Hi")],
                hasMore: true
            )),
            .success(SessionMessagesPage(
                sessionID: "s1",
                messages: [message("3", "assistant", "Hello")],
                hasMore: false
            )),
        ])
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        await transcript.load()
        await transcript.loadMore()

        #expect(await source.requests.map(\.offset) == [0, 2])
        #expect(transcript.lines.map(\.id) == ["3", "2"])
        #expect(!transcript.hasMore)
    }

    @Test("a failed load keeps the failure with its reason")
    func loadFailure() async {
        let source = FakeMessageSource(pages: [.failure(.notFound)])
        let transcript = RemoteTranscript(sessionID: "gone", title: nil, source: source)

        await transcript.load()

        #expect(transcript.state == .failed(.notFound))
        #expect(transcript.lines.isEmpty)
    }

    @Test("cancelling the caller does not cancel the load, as when SwiftUI cancels the view's task")
    func loadOutlivesCaller() async {
        let source = GatedMessageSource(page: SessionMessagesPage(
            sessionID: "s1", messages: [message("1", "user", "Hi")], hasMore: false
        ))
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        let caller = Task { await transcript.load() }
        await waitForPendingRequest(source)
        caller.cancel()
        await source.release()
        await caller.value

        #expect(transcript.state == .loaded)
        #expect(transcript.lines.map(\.text) == ["Hi"])
    }

    @Test("a load called while one is running waits for it and sends no second request")
    func concurrentLoadsShareOneRequest() async {
        let source = GatedMessageSource(page: SessionMessagesPage(
            sessionID: "s1", messages: [message("1", "user", "Hi")], hasMore: false
        ))
        let transcript = RemoteTranscript(sessionID: "s1", title: nil, source: source)

        let first = Task { await transcript.load() }
        await waitForPendingRequest(source)
        let second = Task { await transcript.load() }
        await Task.yield()
        await source.release()
        await first.value
        await second.value

        #expect(await source.requestCount == 1)
        #expect(transcript.state == .loaded)
        #expect(transcript.lines.map(\.text) == ["Hi"])
    }
}

private struct NoImages: StoredImageFetching {
    func image(sha256: String) async throws -> ImageAttachment? { nil }
}
