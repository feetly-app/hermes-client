import HermesAPI
import HermesChat
import SwiftUI

/// Root view. First launch shows the settings alone. Once configured, the conversations, with the settings
/// one button away in the conversation list's toolbar.
struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-HermesMockData") {
            MockConversationsContainer(appState: appState)
        } else if let browser = appState.browser {
            ConversationsView(browser: browser, appState: appState)
        } else {
            SettingsView(appState: appState)
        }
        #else
        if let browser = appState.browser {
            ConversationsView(browser: browser, appState: appState)
        } else {
            SettingsView(appState: appState)
        }
        #endif
    }
}

#if DEBUG
private struct MockConversationsContainer: View {
    let appState: AppState
    @State private var browser: ConversationBrowser?

    var body: some View {
        Group {
            if let browser {
                ConversationsView(browser: browser, appState: appState)
            } else {
                ProgressView()
            }
        }
        .task {
            let s1 = RemoteSession(id: "s1", title: "SwiftUI 3-Column Navigation", startedAt: Date(), lastActive: Date())
            let s2 = RemoteSession(id: "s2", title: "Tailscale Runner Architecture", startedAt: Date(), lastActive: Date().addingTimeInterval(-3600))
            let s3 = RemoteSession(id: "s3", title: "Sidecar Streaming Proxy", startedAt: Date(), lastActive: Date().addingTimeInterval(-7200))

            let p1 = Project(
                id: "p1",
                name: "Hermes Client",
                repositories: [ProjectRepository(id: "r1", name: "hermes-client", url: "https://github.com/maxence-vps/hermes-client")],
                conversationIDs: ["s2"]
            )
            let p2 = Project(
                id: "p2",
                name: "Hermes Sidecar",
                repositories: [ProjectRepository(id: "r2", name: "hermes-sidecar", url: "https://github.com/maxence-vps/hermes-sidecar")],
                conversationIDs: ["s3"]
            )

            let mockListing = MockSessionListing(sessions: [s1, s2, s3])
            let mockProjects = MockProjectStoring(projects: [p1, p2])

            let remoteSessions = RemoteSessionList(source: mockListing)
            let projectList = ProjectList(store: mockProjects)
            let b = ConversationBrowser(remoteSessions: remoteSessions, projects: projectList)
            await b.reloadSessions()
            b.openRemote(s1)
            self.browser = b
        }
    }
}

final class MockSessionListing: SessionListing, @unchecked Sendable {
    var sessions: [RemoteSession]
    init(sessions: [RemoteSession]) { self.sessions = sessions }
    func listSessions(limit: Int, offset: Int) async throws -> SessionPage {
        SessionPage(sessions: sessions, hasMore: false)
    }
    func listSessionMessages(sessionID: String, limit: Int, offset: Int) async throws -> SessionMessagesPage {
        SessionMessagesPage(sessionID: sessionID, messages: [], hasMore: false)
    }
    func streamSessionChat(sessionID: String, message: String, images: [ImageAttachment]) async -> AsyncThrowingStream<SessionChatEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func forkSession(sessionID: String) async throws -> RemoteSession {
        sessions.first(where: { $0.id == sessionID }) ?? RemoteSession(id: sessionID)
    }
    func createSession(model: String?, provider: String?) async throws -> RemoteSession {
        let session = RemoteSession(id: UUID().uuidString, title: "New Conversation")
        sessions.insert(session, at: 0)
        return session
    }
    func renameSession(sessionID: String, title: String) async throws -> RemoteSession {
        let session = RemoteSession(id: sessionID, title: title)
        return session
    }
    func deleteSession(sessionID: String) async throws {
        sessions.removeAll { $0.id == sessionID }
    }
    func getSession(sessionID: String) async throws -> RemoteSession {
        sessions.first(where: { $0.id == sessionID }) ?? RemoteSession(id: sessionID)
    }
}

final class MockProjectStoring: ProjectStoring, @unchecked Sendable {
    var projects: [Project]
    init(projects: [Project]) { self.projects = projects }
    func listProjects() async throws -> [Project] { projects }
    func createProject(name: String) async throws -> Project {
        let p = Project(id: UUID().uuidString, name: name)
        projects.append(p)
        return p
    }
    func renameProject(projectID: String, name: String) async throws -> Project {
        let p = Project(id: projectID, name: name)
        return p
    }
    func deleteProject(projectID: String) async throws {
        projects.removeAll { $0.id == projectID }
    }
    func attachConversation(conversationID: String, projectID: String) async throws {}
    func detachConversation(conversationID: String, projectID: String) async throws {}
    func attachRepository(url: String, projectID: String) async throws -> ProjectRepository {
        ProjectRepository(id: UUID().uuidString, name: "repo", url: url)
    }
    func detachRepository(repositoryID: String, projectID: String) async throws {}
}
#endif
