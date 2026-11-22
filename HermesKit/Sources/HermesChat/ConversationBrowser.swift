import Foundation
import HermesAPI

#if !os(Linux)
    import Observation
#endif

/// The title shown for a conversation the instance has not named yet.
public enum ConversationTitle {
    public static let placeholder = "New conversation"
}

/// The conversation list and the open conversation.
///
/// Every conversation is a session stored on the Hermes instance: a new one is created there, and the
/// instance keeps its messages, title and model. The app keeps no copy. New sessions run on the model set
/// in the connection settings.
///
/// A session created here and left before any message is sent is deleted from the instance, so an
/// abandoned "New conversation" does not stay in the list.
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
    /// `true` while a new session is being created on the instance.
    public private(set) var isCreating = false

    /// The model new sessions are locked on.
    private let model: ModelChoice
    /// Sessions created here in which no message was sent yet.
    private var unsentSessionIDs: Set<String> = []
    /// Sessions left while a reply was streaming. The reply exists only in the transcript that sent the
    /// message: the instance offers no way to attach to a turn already running, so opening the session
    /// again shows that transcript instead of a page read from the instance.
    private var liveTranscripts: [RemoteTranscript] = []

    /// `model` is the model new conversations run on, from the connection settings.
    public init(remoteSessions: RemoteSessionList, model: ModelChoice = .instanceDefault) {
        self.remoteSessions = remoteSessions
        self.model = model
    }

    /// Creates a session on the instance, on the configured model, and opens it.
    ///
    /// The instance default model is not sent: the instance picks its configured model.
    @discardableResult
    public func createConversation() async throws -> RemoteSession {
        let lock = model == ModelChoice.instanceDefault ? nil : model
        isCreating = true
        defer { isCreating = false }
        let session = try await remoteSessions.create(model: lock)
        unsentSessionIDs.insert(session.id)
        closeOpened()
        let transcript = remoteSessions.transcript(for: session, model: model)
        transcript.markEmpty()
        watch(transcript)
        openedRemote = transcript
        return session
    }

    /// Opens a session. Selecting the open one again keeps its transcript, including a reply in progress.
    /// A session left while its reply was streaming opens on the same transcript, with the reply still arriving.
    public func openRemote(_ session: RemoteSession) {
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

    /// Opens the session with this id from the list, or closes the open one with `nil`. An id missing
    /// from the list is ignored.
    public func selectSession(_ sessionID: String?) {
        guard let sessionID else {
            closeOpened()
            return
        }
        if let session = remoteSessions.sessions.first(where: { $0.id == sessionID }) {
            openRemote(session)
        }
    }

    /// Reloads the session list, then gives the open conversation its new title, if the instance named it.
    public func reloadSessions() async {
        await remoteSessions.reload()
        syncOpenedTitle()
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
        Task { try? await remoteSessions.delete(sessionID) }
    }

    /// Follows a reply: once it ends, the session is no longer unsent, and the list is reloaded so that the
    /// row moves up and shows the title the instance may have given it.
    private func watch(_ transcript: RemoteTranscript) {
        transcript.onReplyEnded = { [weak self, weak transcript] in
            guard let self, let transcript else { return }
            unsentSessionIDs.remove(transcript.activeSessionID)
            Task { await self.reloadSessions() }
        }
    }

    private func syncOpenedTitle() {
        guard let openedRemote,
              let session = remoteSessions.sessions.first(where: { $0.id == openedRemote.activeSessionID })
        else { return }
        openedRemote.update(from: session)
    }
}
