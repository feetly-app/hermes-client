import Foundation
import HermesAPI

@testable import HermesChat

/// The session management calls most fakes do not need. A fake that needs one defines it.
extension SessionListing {
    func createSession(model: String?, provider: String?) async throws -> RemoteSession {
        throw HermesAPIError.notFound
    }

    func renameSession(sessionID: String, title: String) async throws -> RemoteSession {
        throw HermesAPIError.notFound
    }

    func deleteSession(sessionID: String) async throws {
        throw HermesAPIError.notFound
    }

    func getSession(sessionID: String) async throws -> RemoteSession {
        throw HermesAPIError.notFound
    }
}

/// An instance that keeps its sessions in memory: creates, lists, renames and deletes them, and answers
/// each message with a scripted reply. Records the calls it receives.
actor FakeInstance: SessionListing {
    struct Created: Equatable {
        let model: String?
        let provider: String?
    }

    private(set) var sessions: [RemoteSession]
    private(set) var created: [Created] = []
    private(set) var renamed: [String] = []
    private(set) var deleted: [String] = []
    private(set) var listCount = 0
    private(set) var messageRequests: [String] = []
    private var nextID = 1
    private var deleteFailure: HermesAPIError?
    /// The title the instance gives a session once a reply ends, as its title generator does.
    private var titleAfterReply: String?

    /// Sessions the instance has but does not list in the first page: only `getSession` finds them.
    private(set) var unlisted: [RemoteSession]
    private(set) var fetched: [String] = []

    init(sessions: [RemoteSession] = [], unlisted: [RemoteSession] = [], titleAfterReply: String? = nil) {
        self.sessions = sessions
        self.unlisted = unlisted
        self.titleAfterReply = titleAfterReply
    }

    func getSession(sessionID: String) async throws -> RemoteSession {
        fetched.append(sessionID)
        guard let session = (sessions + unlisted).first(where: { $0.id == sessionID }) else {
            throw HermesAPIError.notFound
        }
        return session
    }

    func failDeletes(with error: HermesAPIError) {
        deleteFailure = error
    }

    func listSessions(limit: Int, offset: Int) async throws -> SessionPage {
        listCount += 1
        return SessionPage(sessions: sessions, hasMore: false)
    }

    func listSessionMessages(sessionID: String, limit: Int, offset: Int) async throws -> SessionMessagesPage {
        messageRequests.append(sessionID)
        return SessionMessagesPage(sessionID: sessionID, messages: [], hasMore: false)
    }

    func streamSessionChat(
        sessionID: String, message: String, images: [ImageAttachment]
    ) -> AsyncThrowingStream<SessionChatEvent, any Error> {
        if let titleAfterReply, let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index] = RemoteSession(id: sessionID, title: titleAfterReply, source: "api_server")
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed("Reply to \(message)"))
            continuation.finish()
        }
    }

    /// Forks are refused until `allowForks()`: most tests never fork.
    private var forksAllowed = false
    private(set) var forked: [String] = []

    func allowForks() {
        forksAllowed = true
    }

    /// The fork of `x` is `x-fork`, an API session that takes the original's place in the list.
    func forkSession(sessionID: String) async throws -> RemoteSession {
        guard forksAllowed, let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw HermesAPIError.notFound
        }
        forked.append(sessionID)
        let fork = RemoteSession(id: "\(sessionID)-fork", title: sessions[index].title, source: "api_server")
        sessions[index] = fork
        return fork
    }

    func createSession(model: String?, provider: String?) async throws -> RemoteSession {
        created.append(Created(model: model, provider: provider))
        let session = RemoteSession(id: "api_\(nextID)", source: "api_server", model: model)
        nextID += 1
        sessions.insert(session, at: 0)
        return session
    }

    func renameSession(sessionID: String, title: String) async throws -> RemoteSession {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { throw HermesAPIError.notFound }
        renamed.append(title)
        let session = sessions[index]
        sessions[index] = RemoteSession(id: session.id, title: title, source: session.source, model: session.model)
        return sessions[index]
    }

    func deleteSession(sessionID: String) async throws {
        if let deleteFailure {
            throw deleteFailure
        }
        deleted.append(sessionID)
        sessions.removeAll { $0.id == sessionID }
    }
}
