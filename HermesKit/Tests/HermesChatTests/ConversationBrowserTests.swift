import Foundation
import HermesAPI
import Testing

@testable import HermesChat

/// Waits until `condition` holds, for work the browser starts in its own tasks. Gives up after a second.
@MainActor
func waitUntil(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<200 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite("ConversationBrowser")
struct ConversationBrowserTests {
    private func makeBrowser(
        instance: FakeInstance = FakeInstance(),
        model: ModelChoice = ModelChoice(model: "opus", provider: "anthropic")
    ) -> ConversationBrowser {
        ConversationBrowser(remoteSessions: RemoteSessionList(source: instance), model: model)
    }

    // MARK: Start

    @Test("nothing is created or opened on start")
    func startsClosed() async {
        let instance = FakeInstance()
        let browser = makeBrowser(instance: instance)

        #expect(browser.openedRemote == nil)
        #expect(browser.selectedSessionID == nil)
        #expect(await instance.created.isEmpty)
    }

    // MARK: New conversation

    @Test("a new conversation is a session created on the instance with the configured model locked, opened empty")
    func createLocksModel() async throws {
        let instance = FakeInstance()
        let browser = makeBrowser(instance: instance)

        let session = try await browser.createConversation()

        #expect(await instance.created == [FakeInstance.Created(model: "opus", provider: "anthropic")])
        #expect(browser.openedRemote?.sessionID == session.id)
        #expect(browser.openedRemote?.model == ModelChoice(model: "opus", provider: "anthropic"))
        #expect(browser.openedRemote?.state == .loaded)
        #expect(browser.remoteSessions.sessions.first?.id == session.id)
        #expect(browser.selectedSessionID == session.id)
        #expect(!browser.isCreating)
        // Nothing to load: the session was just created.
        #expect(await instance.messageRequests.isEmpty)
    }

    @Test("the instance default model is not sent: the instance picks its configured model")
    func createWithInstanceDefault() async throws {
        let instance = FakeInstance()
        let browser = ConversationBrowser(remoteSessions: RemoteSessionList(source: instance))

        try await browser.createConversation()

        #expect(await instance.created == [FakeInstance.Created(model: nil, provider: nil)])
        #expect(browser.openedRemote?.model == ModelChoice.instanceDefault)
    }

    @Test("a new conversation left before any message is deleted from the instance and the list")
    func abandonedNewConversationIsDeleted() async throws {
        let instance = FakeInstance()
        let browser = makeBrowser(instance: instance)
        let session = try await browser.createConversation()

        browser.selectSession(nil)

        await waitUntil { await instance.deleted == [session.id] }
        #expect(await instance.deleted == [session.id])
        #expect(browser.openedRemote == nil)
        await waitUntil { browser.remoteSessions.sessions.isEmpty }
        #expect(browser.remoteSessions.sessions.isEmpty)
    }

    @Test("a second new conversation replaces an untouched first one")
    func secondNewConversationReplacesUntouched() async throws {
        let instance = FakeInstance()
        let browser = makeBrowser(instance: instance)
        let first = try await browser.createConversation()

        let second = try await browser.createConversation()

        await waitUntil { await instance.deleted == [first.id] }
        #expect(await instance.deleted == [first.id])
        #expect(browser.openedRemote?.sessionID == second.id)
    }

    @Test("a new conversation with a message is kept when left, and gets the title the instance gives it")
    func usedNewConversationIsKept() async throws {
        let instance = FakeInstance(titleAfterReply: "Trip plans")
        let browser = makeBrowser(instance: instance)
        let session = try await browser.createConversation()
        let transcript = try #require(browser.openedRemote)

        await transcript.send("Plan a trip")
        await waitUntil { transcript.title == "Trip plans" }

        #expect(transcript.title == "Trip plans")
        #expect(browser.remoteSessions.sessions.first?.title == "Trip plans")
        browser.selectSession(nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await instance.deleted.isEmpty)
        #expect(browser.remoteSessions.sessions.map(\.id) == [session.id])
    }

    // MARK: Selection

    @Test("opening a session starts loading its messages without the view")
    func openRemoteStartsLoading() async throws {
        let source = GatedMessageSource(page: SessionMessagesPage(
            sessionID: "remote-1",
            messages: [SessionMessage(id: "1", role: "user", content: "Hi")],
            hasMore: false
        ))
        let browser = ConversationBrowser(remoteSessions: RemoteSessionList(source: source))

        browser.openRemote(RemoteSession(id: "remote-1"))
        await waitUntil { await source.pendingCount == 1 }
        await source.release()
        let transcript = try #require(browser.openedRemote)
        await waitUntil { transcript.state == .loaded }

        #expect(transcript.lines.map(\.text) == ["Hi"])
        #expect(await source.requestCount == 1)
    }

    @Test("a session id from the list opens it, nil closes it")
    func selectSessionOpensRows() async throws {
        let instance = FakeInstance(sessions: [RemoteSession(id: "remote-1", title: "Notes")])
        let browser = makeBrowser(instance: instance)
        await browser.reloadSessions()

        browser.selectSession("remote-1")
        #expect(browser.openedRemote?.title == "Notes")
        #expect(browser.selectedSessionID == "remote-1")

        browser.selectSession(nil)
        #expect(browser.openedRemote == nil)
        #expect(browser.selectedSessionID == nil)
    }

    @Test("selecting the open session again keeps its transcript; an unknown id changes nothing")
    func reselectKeepsTranscript() async {
        let instance = FakeInstance(sessions: [RemoteSession(id: "remote-1")])
        let browser = makeBrowser(instance: instance)
        await browser.reloadSessions()
        browser.selectSession("remote-1")
        let transcript = browser.openedRemote

        browser.selectSession("remote-1")
        browser.selectSession("unknown")

        #expect(browser.openedRemote === transcript)
    }

    // MARK: Rename and delete on the instance

    @Test("renaming a session renames it on the instance and in the open conversation, in place")
    func renameSession() async throws {
        let instance = FakeInstance(sessions: [RemoteSession(id: "a", title: "A"), RemoteSession(id: "b", title: "B")])
        let browser = makeBrowser(instance: instance)
        await browser.reloadSessions()
        browser.selectSession("b")

        try await browser.renameSession("b", to: "  Budget  ")
        try await browser.renameSession("b", to: "   ")

        #expect(await instance.renamed == ["Budget"])
        #expect(browser.remoteSessions.sessions.map(\.title) == ["A", "Budget"])
        #expect(browser.openedRemote?.title == "Budget")
    }

    @Test("deleting the open session deletes it on the instance, removes its row and closes it")
    func deleteOpenSession() async throws {
        let instance = FakeInstance(sessions: [RemoteSession(id: "a"), RemoteSession(id: "b")])
        let browser = makeBrowser(instance: instance)
        await browser.reloadSessions()
        browser.selectSession("b")

        try await browser.deleteSession("b")

        #expect(await instance.deleted == ["b"])
        #expect(browser.remoteSessions.sessions.map(\.id) == ["a"])
        #expect(browser.openedRemote == nil)
    }

    @Test("a refused delete keeps the row and the open session")
    func refusedDelete() async {
        let instance = FakeInstance(sessions: [RemoteSession(id: "a")])
        await instance.failDeletes(with: .http(status: 409))
        let browser = makeBrowser(instance: instance)
        await browser.reloadSessions()
        browser.selectSession("a")

        await #expect(throws: HermesAPIError.http(status: 409)) {
            try await browser.deleteSession("a")
        }

        #expect(browser.remoteSessions.sessions.map(\.id) == ["a"])
        #expect(browser.openedRemote?.sessionID == "a")
    }
}
