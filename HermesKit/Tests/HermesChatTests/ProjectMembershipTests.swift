import Foundation
import HermesAPI
import Testing

@testable import HermesChat

@MainActor
@Suite("Project membership across forks and deletions")
struct ProjectMembershipTests {
    /// A session created in the web dashboard: the API refuses messages in it, so the first one forks it.
    private static let dashboard = RemoteSession(id: "x", title: "From the dashboard", source: "local")
    private static let apiSession = RemoteSession(id: "a", title: "Alpha", source: "api_server")

    private func makeBrowser(instance: FakeInstance, store: FakeProjectStore) -> ConversationBrowser {
        ConversationBrowser(remoteSessions: RemoteSessionList(source: instance), projects: ProjectList(store: store))
    }

    private static func hasCall(_ store: FakeProjectStore, _ call: FakeProjectStore.Call) async -> Bool {
        await store.calls.contains(call)
    }

    // MARK: Fork

    @Test("after a fork, the fork is put in the original's project and the original is taken out")
    func forkStaysInProject() async throws {
        let instance = FakeInstance(sessions: [Self.dashboard])
        await instance.allowForks()
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["x"])])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()
        browser.select(.project("p1"))
        browser.openRemote(Self.dashboard, inProject: "p1")
        let transcript = try #require(browser.openedRemote)
        // Opening starts loading the messages: the page would replace the lines of the reply.
        await waitUntil { transcript.state == .loaded }

        await transcript.send("Hi")
        await waitUntil { await Self.hasCall(store, .detach(conversation: "x", project: "p1")) }

        // The list reload that follows the reply may race with the membership calls: reload once they ended.
        await browser.reloadSessions()

        #expect(transcript.activeSessionID == "x-fork")
        #expect(transcript.lines.last?.text == "Reply to Hi")
        let calls = await store.calls
        let attach = try #require(calls.firstIndex(of: .attach(conversation: "x-fork", project: "p1")))
        let detach = try #require(calls.firstIndex(of: .detach(conversation: "x", project: "p1")))
        #expect(attach < detach)
        let project = try #require(browser.projects?.project(id: "p1"))
        #expect(project.conversationIDs == ["x-fork"])
        #expect(browser.conversations(in: project).map(\.id) == ["x-fork"])
        #expect(browser.recentSessions.isEmpty)
        #expect(browser.selection == .project("p1"))
        #expect(browser.projectNotice == nil)
    }

    @Test("if the fork cannot be attached, the message is sent anyway and a notice reports it")
    func forkAttachFails() async throws {
        let instance = FakeInstance(sessions: [Self.dashboard])
        await instance.allowForks()
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["x"])])
        await store.fail("attach", with: .api(.network))
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()
        browser.openRemote(Self.dashboard, inProject: "p1")
        let transcript = try #require(browser.openedRemote)
        // Opening starts loading the messages: the page would replace the lines of the reply.
        await waitUntil { transcript.state == .loaded }

        await transcript.send("Hi")
        await waitUntil { browser.projectNotice != nil }

        #expect(transcript.lines.last?.text == "Reply to Hi")
        #expect(transcript.sendError == nil)
        #expect(browser.projectNotice?.contains("Hermes") == true)
        // The original is not taken out of a project its fork could not join.
        #expect(!(await Self.hasCall(store, .detach(conversation: "x", project: "p1"))))
    }

    @Test("a fork of a conversation in no project changes no project")
    func forkOutsideProjects() async throws {
        let instance = FakeInstance(sessions: [Self.dashboard])
        await instance.allowForks()
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes")])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()
        browser.select(.session("x"))
        let transcript = try #require(browser.openedRemote)
        // Opening starts loading the messages: the page would replace the lines of the reply.
        await waitUntil { transcript.state == .loaded }

        await transcript.send("Hi")

        #expect(transcript.activeSessionID == "x-fork")
        let calls = await store.calls
        #expect(calls.allSatisfy { $0 == .list })
        #expect(browser.recentSessions.map(\.id) == ["x-fork"])
    }

    // MARK: Delete

    @Test("a conversation deleted on the instance is taken out of its project")
    func deleteDetaches() async throws {
        let instance = FakeInstance(sessions: [Self.apiSession])
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["a"])])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()

        try await browser.deleteSession("a")

        #expect(await instance.deleted == ["a"])
        #expect(await Self.hasCall(store, .detach(conversation: "a", project: "p1")))
        #expect(browser.projects?.project(id: "p1")?.conversationIDs.isEmpty == true)
        #expect(await store.projects.first?.conversationIDs.isEmpty == true)
    }

    @Test("a failed detach after a delete is silent")
    func deleteDetachFails() async throws {
        let instance = FakeInstance(sessions: [Self.apiSession])
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["a"])])
        await store.fail("detach", with: .api(.network))
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()

        try await browser.deleteSession("a")

        #expect(await instance.deleted == ["a"])
        #expect(browser.projectNotice == nil)
        #expect(browser.remoteSessions.sessions.isEmpty)
    }

    @Test("a delete Hermes refuses leaves the project as it was")
    func refusedDeleteKeepsMembership() async throws {
        let instance = FakeInstance(sessions: [Self.apiSession])
        await instance.failDeletes(with: .http(status: 409))
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["a"])])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()

        await #expect(throws: HermesAPIError.http(status: 409)) { try await browser.deleteSession("a") }

        #expect(await store.calls == [.list])
        #expect(browser.projects?.project(id: "p1")?.conversationIDs == ["a"])
    }

    @Test("a new conversation left in its project without a message is deleted and taken out of the project")
    func abandonedConversationDetached() async throws {
        let instance = FakeInstance()
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes")])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()
        browser.select(.project("p1"))
        let session = try await browser.createConversation(inProject: "p1")

        browser.closeConversation()
        await waitUntil { await Self.hasCall(store, .detach(conversation: session.id, project: "p1")) }

        #expect(await instance.deleted == [session.id])
        #expect(browser.projects?.project(id: "p1")?.conversationIDs.isEmpty == true)
        #expect(browser.selection == .project("p1"))
    }
}
