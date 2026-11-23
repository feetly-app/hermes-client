import Foundation
import HermesAPI
import Testing

@testable import HermesChat

@MainActor
@Suite("ConversationBrowser projects")
struct ConversationBrowserProjectsTests {
    private static let sessions = [
        RemoteSession(id: "a", title: "Alpha", lastActive: Date(timeIntervalSince1970: 300), source: "api_server"),
        RemoteSession(id: "b", title: "Beta", lastActive: Date(timeIntervalSince1970: 200), source: "api_server"),
        RemoteSession(id: "c", title: "Gamma", lastActive: Date(timeIntervalSince1970: 100), source: "api_server"),
    ]

    private func makeBrowser(
        instance: FakeInstance = FakeInstance(sessions: ConversationBrowserProjectsTests.sessions),
        store: FakeProjectStore? = FakeProjectStore(projects: [
            Project(id: "p1", name: "Hermes", conversationIDs: ["b"]),
        ])
    ) -> ConversationBrowser {
        ConversationBrowser(
            remoteSessions: RemoteSessionList(source: instance),
            projects: store.map { ProjectList(store: $0) }
        )
    }

    @Test("reloading loads the sessions and the projects; Recents leaves out the conversations in a project")
    func recentsFilter() async {
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["b"])])
        let browser = makeBrowser(store: store)

        await browser.reloadSessions()

        #expect(await store.calls == [.list])
        #expect(browser.projects?.state == .loaded)
        #expect(browser.recentSessions.map(\.id) == ["a", "c"])
        #expect(browser.remoteSessions.recentFirst.map(\.id) == ["a", "b", "c"])
    }

    @Test("when the projects cannot be loaded, Recents shows every conversation")
    func failedProjects() async {
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["b"])])
        await store.fail("list", with: .api(.network))
        let browser = makeBrowser(store: store)

        await browser.reloadSessions()

        #expect(browser.projects?.state == .failed(.api(.network)))
        #expect(browser.recentSessions.map(\.id) == ["a", "b", "c"])
    }

    @Test("without a sidecar there is no project list, and Recents shows every conversation")
    func noSidecar() async {
        let browser = makeBrowser(store: nil)
        await browser.reloadSessions()
        #expect(browser.projects == nil)
        #expect(browser.recentSessions.map(\.id) == ["a", "b", "c"])
        browser.select(.project("p1"))
        #expect(browser.selection == nil)
    }

    @Test("selecting a project opens it and closes the open conversation; selecting a conversation closes the project")
    func selection() async {
        let browser = makeBrowser()
        await browser.reloadSessions()

        browser.select(.session("a"))
        #expect(browser.selection == .session("a"))

        browser.select(.project("p1"))
        #expect(browser.selection == .project("p1"))
        #expect(browser.openedProject?.name == "Hermes")
        #expect(browser.openedRemote == nil)

        browser.select(.session("c"))
        #expect(browser.selection == .session("c"))
        #expect(browser.openedProjectID == nil)

        browser.select(nil)
        #expect(browser.selection == nil)
    }

    @Test("a created project is added to the list and opens")
    func createProject() async throws {
        let browser = makeBrowser()
        await browser.reloadSessions()

        let project = try await browser.createProject(named: "Inbox")

        #expect(browser.projects?.projects.map(\.name) == ["Hermes", "Inbox"])
        #expect(browser.selection == .project(project.id))
    }

    @Test("a refused name throws its error and opens nothing")
    func createRefused() async {
        let store = FakeProjectStore()
        await store.fail("create", with: .nameTaken)
        let browser = makeBrowser(store: store)
        await browser.reloadSessions()

        await #expect(throws: ProjectError.nameTaken) { try await browser.createProject(named: "Hermes") }
        #expect(browser.selection == nil)
    }

    @Test("deleting the open project closes it, and its conversations are back in Recents, still on the instance")
    func deleteProject() async throws {
        let instance = FakeInstance(sessions: Self.sessions)
        let browser = makeBrowser(instance: instance)
        await browser.reloadSessions()
        browser.select(.project("p1"))

        try await browser.deleteProject("p1")

        #expect(browser.selection == nil)
        #expect(browser.recentSessions.map(\.id) == ["a", "b", "c"])
        #expect(await instance.deleted.isEmpty)
    }

    @Test("an open project deleted elsewhere closes on the next reload")
    func projectGoneElsewhere() async {
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes", conversationIDs: ["b"])])
        let browser = makeBrowser(store: store)
        await browser.reloadSessions()
        browser.select(.project("p1"))

        try? await store.deleteProject(projectID: "p1")
        await browser.reloadSessions()

        #expect(browser.openedProjectID == nil)
    }

    @Test("an open project stays open while the projects cannot be loaded")
    func projectKeptOnFailure() async {
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes")])
        let browser = makeBrowser(store: store)
        await browser.reloadSessions()
        browser.select(.project("p1"))

        await store.fail("list", with: .api(.network))
        await browser.reloadSessions()

        #expect(browser.openedProjectID == "p1")
    }

    @Test("a new conversation from the sidebar is created outside any project and closes the open project")
    func newConversationOutsideProjects() async throws {
        let store = FakeProjectStore(projects: [Project(id: "p1", name: "Hermes")])
        let browser = makeBrowser(store: store)
        await browser.reloadSessions()
        browser.select(.project("p1"))

        let session = try await browser.createConversation()

        #expect(browser.selection == .session(session.id))
        let calls = await store.calls
        #expect(!calls.contains { call in
            if case .attach = call { return true }
            return false
        })
    }

    @Test("the project search matches names, ignoring case and accents")
    func searchProjects() {
        let projects = [Project(id: "1", name: "Équipe"), Project(id: "2", name: "Hermes"), Project(id: "3", name: "Notes")]
        #expect(projects.matching("equi").map(\.id) == ["1"])
        #expect(projects.matching("ES").map(\.id) == ["2", "3"])
        #expect(projects.matching("  ").map(\.id) == ["1", "2", "3"])
    }
}
