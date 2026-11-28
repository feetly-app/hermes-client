import Foundation
import HermesAPI
import Testing

@testable import HermesChat

@MainActor
@Suite("Project screen")
struct ProjectScreenTests {
    private static let listed = [
        RemoteSession(id: "a", title: "Alpha", lastActive: Date(timeIntervalSince1970: 100), source: "api_server"),
        RemoteSession(id: "b", title: "Beta", lastActive: Date(timeIntervalSince1970: 300), source: "api_server"),
    ]
    private static let older = RemoteSession(
        id: "old", title: "Older", lastActive: Date(timeIntervalSince1970: 200), source: "api_server"
    )

    private func makeBrowser(
        instance: FakeInstance,
        store: FakeProjectStore
    ) -> ConversationBrowser {
        ConversationBrowser(remoteSessions: RemoteSessionList(source: instance), projects: ProjectList(store: store))
    }

    @Test("a project's conversations are the listed ones plus those fetched by id, most recent first; orphans are hidden")
    func conversations() async throws {
        let instance = FakeInstance(sessions: Self.listed, unlisted: [Self.older])
        let store = FakeProjectStore(projects: [
            Project(id: "p1", name: "Hermes", conversationIDs: ["a", "b", "old", "gone"]),
        ])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()
        let project = try #require(browser.projects?.project(id: "p1"))

        #expect(browser.conversations(in: project).map(\.id) == ["b", "a"])

        await browser.loadConversations(in: project)

        #expect(browser.conversations(in: project).map(\.id) == ["b", "old", "a"])
        #expect(Set(await instance.fetched) == ["old", "gone"])
        #expect(browser.remoteSessions.knowsAll(project.conversationIDs))

        // Known and orphan ids are not asked for again.
        await browser.loadConversations(in: project)
        #expect(await instance.fetched.count == 2)
    }

    @Test("a conversation opened from the project screen keeps the project selected; back closes only the chat")
    func openFromProject() async throws {
        let instance = FakeInstance(sessions: Self.listed)
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["a"])])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()
        browser.select(.project("p1"))

        browser.openRemote(Self.listed[0], inProject: "p1")

        #expect(browser.openedRemote?.sessionID == "a")
        #expect(browser.selection == .project("p1"))

        browser.closeConversation()

        #expect(browser.openedRemote == nil)
        #expect(browser.selection == .project("p1"))
    }

    @Test("back from a project screen closes the project and keeps the open conversation")
    func closeProject() async throws {
        let instance = FakeInstance(sessions: Self.listed)
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["a"])])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()
        browser.openRemote(Self.listed[0], inProject: "p1")

        browser.closeProject()

        #expect(browser.openedProjectID == nil)
        #expect(browser.openedRemote?.sessionID == "a")
        #expect(browser.selection == .session("a"))
    }

    @Test("a session opens by id, over a project; the same id again keeps its transcript; an unknown id is ignored")
    func openSessionByID() async throws {
        let instance = FakeInstance(sessions: Self.listed, unlisted: [Self.older])
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["old"])])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()

        #expect(!browser.openSession("old", inProject: "p1"))
        #expect(browser.openedRemote == nil)

        let project = try #require(browser.projects?.project(id: "p1"))
        await browser.loadConversations(in: project)
        #expect(browser.openSession("old", inProject: "p1"))
        let transcript = try #require(browser.openedRemote)
        #expect(transcript.sessionID == "old")
        #expect(browser.openedProjectID == "p1")
        #expect(browser.isOpen("old"))
        #expect(!browser.isOpen("a"))

        #expect(browser.openSession("old"))
        #expect(browser.openedRemote === transcript)
        #expect(browser.openedProjectID == nil)
    }

    @Test("a conversation created in a project is attached before it opens, over the project")
    func createInProject() async throws {
        let instance = FakeInstance()
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes")])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()
        browser.select(.project("p1"))

        let session = try await browser.createConversation(inProject: "p1")

        #expect(await store.calls.last == .attach(conversation: session.id, project: "p1"))
        #expect(browser.projects?.project(containing: session.id)?.id == "p1")
        #expect(browser.openedRemote?.sessionID == session.id)
        #expect(browser.selection == .project("p1"))
        #expect(browser.recentSessions.isEmpty)
        #expect(browser.projectNotice == nil)
    }

    @Test("if the attach fails, the conversation still opens, in Recents, and a notice says why")
    func createInProjectAttachFails() async throws {
        let instance = FakeInstance()
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes")])
        await store.fail("attach", with: .api(.network))
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()
        browser.select(.project("p1"))

        let session = try await browser.createConversation(inProject: "p1")

        #expect(browser.openedRemote?.sessionID == session.id)
        #expect(browser.selection == .session(session.id))
        #expect(browser.recentSessions.map(\.id) == [session.id])
        #expect(browser.projectNotice?.hasPrefix("The conversation could not be added to the project.") == true)

        browser.dismissProjectNotice()
        #expect(browser.projectNotice == nil)
    }

    @Test("the open project, also while one of its chats is open, is where ⌘N creates the conversation")
    func currentProjectForNewConversation() async throws {
        let instance = FakeInstance(sessions: Self.listed)
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["a"])])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()

        browser.select(.project("p1"))
        browser.openRemote(Self.listed[0], inProject: "p1")
        #expect(browser.openedProjectID == "p1")

        browser.select(.session("b"))
        #expect(browser.openedProjectID == nil)
    }

    @Test("a project deleted elsewhere while one of its chats is open closes; the chat stays open")
    func projectGoneWithChatOpen() async throws {
        let instance = FakeInstance(sessions: Self.listed)
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["a"])])
        let browser = makeBrowser(instance: instance, store: store)
        await browser.reloadSessions()
        browser.select(.project("p1"))
        browser.openRemote(Self.listed[0], inProject: "p1")

        try await store.deleteProject(projectID: "p1")
        await browser.reloadSessions()

        #expect(browser.openedProjectID == nil)
        #expect(browser.openedRemote?.sessionID == "a")
        #expect(browser.selection == .session("a"))
    }
}
