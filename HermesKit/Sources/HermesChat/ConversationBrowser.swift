import Foundation
import HermesAPI

#if !os(Linux)
    import Observation
#endif

/// The title shown for a conversation the instance has not named yet.
public enum ConversationTitle {
    public static let placeholder = "New conversation"
}

/// What the sidebar selects: a project, or a conversation outside any project.
public enum SidebarItem: Hashable, Sendable {
    case project(String)
    case session(String)
}

/// The conversation list, the projects, and what is open: a conversation or a project.
///
/// Every conversation is a session stored on the Hermes instance: a new one is created there, and the
/// instance keeps its messages, title and model. The app keeps no copy. New sessions run on the model set
/// in the connection settings.
///
/// A session created here and left before any message is sent is deleted from the instance, so an
/// abandoned "New conversation" does not stay in the list.
///
/// With a sidecar, `projects` holds the Projects. A conversation in a project is left out of `recentSessions`
/// while the projects are loaded; if they cannot be loaded, every conversation shows in it.
///
/// `@Observable` is applied on Apple platforms, see `RemoteSessionList` for why it is left out on Linux.
@MainActor
#if !os(Linux)
    @Observable
#endif
public final class ConversationBrowser {
    /// The open session.
    public private(set) var openedRemote: RemoteTranscript?
    public let remoteSessions: RemoteSessionList
    /// The projects of the sidecar, or `nil` without a sidecar: the app then has no projects.
    public let projects: ProjectList?
    /// The open project, or `nil`.
    public private(set) var openedProjectID: String?
    /// `true` while a new session is being created on the instance.
    public private(set) var isCreating = false
    /// Why the last change of project membership failed, for an alert that does not block the chat. `nil` once
    /// dismissed (`dismissProjectNotice()`).
    public private(set) var projectNotice: String?

    /// The model new sessions are locked on.
    private let model: ModelChoice
    /// Sessions created here in which no message was sent yet.
    private var unsentSessionIDs: Set<String> = []
    /// Sessions left while a reply was streaming. The reply exists only in the transcript that sent the
    /// message: the instance offers no way to attach to a turn already running, so opening the session
    /// again shows that transcript instead of a page read from the instance.
    private var liveTranscripts: [RemoteTranscript] = []

    /// `model` is the model new conversations run on, from the connection settings. `projects` is `nil`
    /// without a sidecar.
    public init(remoteSessions: RemoteSessionList, projects: ProjectList? = nil, model: ModelChoice = .instanceDefault) {
        self.remoteSessions = remoteSessions
        self.projects = projects
        self.model = model
    }

    /// The conversations in no project, most recent activity first: the Recents of the sidebar.
    public var recentSessions: [RemoteSession] {
        let inProjects = projects?.conversationIDs ?? []
        let sessions = remoteSessions.recentFirst
        return inProjects.isEmpty ? sessions : sessions.filter { !inProjects.contains($0.id) }
    }

    /// The open project, or `nil`.
    public var openedProject: Project? {
        openedProjectID.flatMap { projects?.project(id: $0) }
    }

    /// Creates a session on the instance, on the configured model, and opens it.
    ///
    /// With a `projectID`, the session is put in that project before it opens, and opens over the project
    /// screen. If that fails, it still opens, outside any project (it is in Recents), and `projectNotice` says
    /// why. Without one, it opens outside any project and the open project closes.
    ///
    /// The instance default model is not sent: the instance picks its configured model.
    @discardableResult
    public func createConversation(inProject projectID: String? = nil) async throws -> RemoteSession {
        let lock = model == ModelChoice.instanceDefault ? nil : model
        isCreating = true
        defer { isCreating = false }
        let session = try await remoteSessions.create(model: lock)
        unsentSessionIDs.insert(session.id)
        var keptProjectID: String?
        if let projectID, let projects {
            do {
                try await projects.attach(session.id, to: projectID)
                keptProjectID = projectID
            } catch {
                projectNotice = "The conversation could not be added to the project. \(Self.reason(error))"
            }
        }
        closeOpened()
        openedProjectID = keptProjectID
        let transcript = remoteSessions.transcript(for: session, model: model)
        transcript.markEmpty()
        watch(transcript)
        openedRemote = transcript
        return session
    }

    /// Opens a session. Selecting the open one again keeps its transcript, including a reply in progress.
    /// A session left while its reply was streaming opens on the same transcript, with the reply still arriving.
    ///
    /// With a `projectID`, the conversation opens over that project's screen, which stays selected in the
    /// sidebar. Without one, the open project closes.
    public func openRemote(_ session: RemoteSession, inProject projectID: String? = nil) {
        openedProjectID = projectID.flatMap { projects?.project(id: $0) != nil ? $0 : nil }
        // After a fork the sidebar row carries the fork's id, which is the transcript's active session.
        if let openedRemote, openedRemote.sessionID == session.id || openedRemote.activeSessionID == session.id {
            return
        }
        closeOpened()
        if let index = liveTranscripts.firstIndex(where: {
            $0.sessionID == session.id || $0.activeSessionID == session.id
        }) {
            // Not loaded again: the page would replace the lines, the reply being streamed included.
            openedRemote = liveTranscripts.remove(at: index)
            return
        }
        let transcript = remoteSessions.transcript(for: session)
        watch(transcript)
        openedRemote = transcript
        // Loaded from here, not only from the view: on iOS 27 the detail view of a collapsed split view
        // can miss its `.task`, or have it cancelled at once, and the transcript would stay empty.
        Task { await transcript.load() }
    }

    /// The id of the open session's row. After a fork the row carries the fork's id, the transcript's
    /// active session.
    public var selectedSessionID: String? {
        openedRemote?.activeSessionID
    }

    /// What the sidebar shows selected: the open project, else the open conversation.
    public var selection: SidebarItem? {
        if let openedProjectID {
            return .project(openedProjectID)
        }
        return selectedSessionID.map { .session($0) }
    }

    /// Opens what the sidebar selected, or closes everything with `nil`.
    public func select(_ item: SidebarItem?) {
        switch item {
        case .project(let projectID):
            openProject(projectID)
        case .session(let sessionID):
            selectSession(sessionID)
        case nil:
            openedProjectID = nil
            closeOpened()
        }
    }

    /// Opens a project, closing the open conversation. An id missing from the projects is ignored.
    public func openProject(_ projectID: String) {
        guard projects?.project(id: projectID) != nil else { return }
        guard openedProjectID != projectID else { return }
        closeOpened()
        openedProjectID = projectID
    }

    /// Closes the open conversation and keeps the open project: back from a chat to its project screen.
    public func closeConversation() {
        closeOpened()
    }

    /// Clears `projectNotice` once the alert is dismissed.
    public func dismissProjectNotice() {
        projectNotice = nil
    }

    /// The conversations of a project, most recent activity first. Those not fetched yet are missing until
    /// `loadConversations(in:)` ends; orphans (gone from the instance) are left out.
    public func conversations(in project: Project) -> [RemoteSession] {
        remoteSessions.sessions(withIDs: project.conversationIDs)
    }

    /// Fetches by id the conversations of a project the loaded pages do not hold.
    public func loadConversations(in project: Project) async {
        await remoteSessions.fetchMissing(project.conversationIDs)
    }

    /// Opens the session with this id from the list, or closes the open one with `nil`. An id missing
    /// from the list is ignored.
    public func selectSession(_ sessionID: String?) {
        guard let sessionID else {
            openedProjectID = nil
            closeOpened()
            return
        }
        if let session = remoteSessions.sessions.first(where: { $0.id == sessionID }) {
            openRemote(session)
        }
    }

    /// Reloads the session list and the projects, then gives the open conversation its new title, if the
    /// instance named it. A project that is gone from the sidecar closes.
    public func reloadSessions() async {
        async let projectsReloaded: Void = reloadProjects()
        await remoteSessions.reload()
        await projectsReloaded
        syncOpenedTitle()
        syncOpenedProject()
    }

    /// Creates a project on the sidecar and opens it. Throws `ProjectError`, for example `nameTaken` or
    /// `invalidName`. Without a sidecar there are no projects: throws `ProjectError.projectNotFound`.
    @discardableResult
    public func createProject(named name: String) async throws -> Project {
        guard let projects else { throw ProjectError.projectNotFound }
        let project = try await projects.create(name: name)
        openProject(project.id)
        return project
    }

    /// Renames a project on the sidecar.
    public func renameProject(_ projectID: String, to name: String) async throws {
        guard let projects else { throw ProjectError.projectNotFound }
        try await projects.rename(projectID, to: name)
    }

    /// Deletes a project on the sidecar, and closes it if it is open. Its conversations stay on the instance
    /// and show in Recents again.
    public func deleteProject(_ projectID: String) async throws {
        guard let projects else { throw ProjectError.projectNotFound }
        defer { syncOpenedProject() }
        try await projects.delete(projectID)
    }

    /// Attaches a repository to a project on the sidecar. Throws `ProjectError`.
    @discardableResult
    public func attachRepository(url: String, to projectID: String) async throws -> ProjectRepository {
        guard let projects else { throw ProjectError.projectNotFound }
        return try await projects.attachRepository(url: url, to: projectID)
    }

    /// Detaches a repository from a project on the sidecar. Throws `ProjectError`.
    public func detachRepository(_ repositoryID: String, from projectID: String) async throws {
        guard let projects else { throw ProjectError.projectNotFound }
        try await projects.detachRepository(repositoryID, from: projectID)
    }

    /// Renames a session on the instance. A blank title is ignored.
    public func renameSession(_ sessionID: String, to title: String) async throws {
        try await remoteSessions.rename(sessionID, to: title)
        syncOpenedTitle()
    }

    /// Deletes a session on the instance. The open one is stopped and closed first.
    public func deleteSession(_ sessionID: String) async throws {
        let isOpen = openedRemote.map { $0.sessionID == sessionID || $0.activeSessionID == sessionID } ?? false
        if isOpen {
            openedRemote?.stop()
        }
        if let index = liveTranscripts.firstIndex(where: {
            $0.sessionID == sessionID || $0.activeSessionID == sessionID
        }) {
            liveTranscripts.remove(at: index).stop()
        }
        try await remoteSessions.delete(sessionID)
        unsentSessionIDs.remove(sessionID)
        if isOpen {
            openedRemote = nil
        }
        await detachFromProject(sessionID)
    }

    // MARK: Private

    /// Closes the open conversation. A session created here and left without a message is deleted. One
    /// left while a reply streams is kept; kept transcripts whose reply ended are dropped, the instance
    /// holds all of their messages.
    private func closeOpened() {
        defer { liveTranscripts.removeAll { !$0.isSending } }
        guard let transcript = openedRemote else { return }
        openedRemote = nil
        if transcript.isSending, !liveTranscripts.contains(where: { $0 === transcript }) {
            liveTranscripts.append(transcript)
        }
        let sessionID = transcript.activeSessionID
        guard unsentSessionIDs.remove(sessionID) != nil, !transcript.hasSent else { return }
        Task {
            guard (try? await remoteSessions.delete(sessionID)) != nil else { return }
            await detachFromProject(sessionID)
        }
    }

    /// Takes a session deleted on the instance out of its project, so the project no longer names it. Best
    /// effort and silent: a project that still names it shows nothing for it, the instance answers `404`.
    private func detachFromProject(_ sessionID: String) async {
        guard let projects, let project = projects.project(containing: sessionID) else { return }
        try? await projects.detach(sessionID, from: project.id)
    }

    /// The sidecar knows conversations by session id only. When a session created elsewhere is forked to take
    /// a message, the fork goes in the original's project and the original leaves it. The message is sent
    /// whatever happens; a failed attach only sets `projectNotice`, a failed detach is ignored.
    private func carryProjectMembership(from originalID: String, to forkID: String) {
        guard let projects, let project = projects.project(containing: originalID) else { return }
        Task {
            do {
                try await projects.attach(forkID, to: project.id)
            } catch {
                projectNotice = "The conversation continues outside “\(project.name)”: it could not be kept in the "
                    + "project. \(Self.reason(error))"
                return
            }
            try? await projects.detach(originalID, from: project.id)
        }
    }

    /// Follows a reply: once it ends, the session is no longer unsent, and the list is reloaded so that the
    /// row moves up and shows the title the instance may have given it.
    private func watch(_ transcript: RemoteTranscript) {
        let onFork = transcript.onFork
        let originalID = transcript.sessionID
        transcript.onFork = { [weak self] fork in
            onFork?(fork)
            self?.carryProjectMembership(from: originalID, to: fork.id)
        }
        transcript.onReplyEnded = { [weak self, weak transcript] in
            guard let self, let transcript else { return }
            unsentSessionIDs.remove(transcript.activeSessionID)
            Task { await self.reloadSessions() }
        }
    }

    private static func reason(_ error: any Error) -> String {
        ProjectError.from(error).errorDescription ?? "The request failed."
    }

    private func reloadProjects() async {
        await projects?.reload()
    }

    /// Closes the open project once the sidecar no longer lists it (deleted here or elsewhere). Kept while the
    /// projects cannot be loaded: it may come back.
    private func syncOpenedProject() {
        guard let openedProjectID, let projects, projects.state == .loaded,
              projects.project(id: openedProjectID) == nil
        else { return }
        self.openedProjectID = nil
    }

    private func syncOpenedTitle() {
        guard let openedRemote,
              let session = remoteSessions.sessions.first(where: { $0.id == openedRemote.activeSessionID })
        else { return }
        openedRemote.update(from: session)
    }
}
