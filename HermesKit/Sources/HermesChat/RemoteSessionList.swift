import Foundation
import HermesAPI

#if !os(Linux)
    import Observation
#endif

/// The session endpoints of a Hermes instance: list, read, create, rename, delete and chat.
/// `HermesClient` conforms; tests provide a fake.
public protocol SessionListing: Sendable {
    func listSessions(limit: Int, offset: Int) async throws -> SessionPage
    func listSessionMessages(sessionID: String, limit: Int, offset: Int) async throws -> SessionMessagesPage
    func streamSessionChat(
        sessionID: String, message: String, images: [ImageAttachment]
    ) async -> AsyncThrowingStream<SessionChatEvent, any Error>
    func forkSession(sessionID: String) async throws -> RemoteSession
    func createSession(model: String?, provider: String?) async throws -> RemoteSession
    func renameSession(sessionID: String, title: String) async throws -> RemoteSession
    func deleteSession(sessionID: String) async throws
}

extension HermesClient: SessionListing {}

/// The sessions stored on the Hermes instance: every conversation of the app.
///
/// Pages are requested with an offset. The instance back-fills pinned sessions past the limit, so the
/// offset counts only the unpinned rows received; counting every row would skip some of them.
///
/// `@Observable` is applied on Apple platforms only: the Observation library does not link with the
/// Linux toolchain used to run the tests.
@MainActor
#if !os(Linux)
    @Observable
#endif
public final class RemoteSessionList {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(HermesAPIError)
    }

    /// Page size requested from the instance.
    public static let pageSize = 50

    public private(set) var sessions: [RemoteSession] = []
    public private(set) var state: State = .idle
    public private(set) var hasMore = false

    private let source: any SessionListing
    private let storedImages: StoredImageLoader?
    /// Number of unpinned rows received so far, which is the offset of the next page.
    private var windowOffset = 0

    /// `storedImages` gets back the images stored messages name, through the sidecar. `nil` without one:
    /// transcripts then show those images as not available.
    public init(source: any SessionListing, storedImages: StoredImageLoader? = nil) {
        self.source = source
        self.storedImages = storedImages
    }

    public var isLoading: Bool {
        state == .loading
    }

    /// The sessions, most recent activity first: the last activity of a session, or its start time when
    /// that is missing. Sessions without any date go last. Ties are broken by id, so the order is stable.
    public var recentFirst: [RemoteSession] {
        sessions.sorted { lhs, rhs in
            switch (lhs.lastActive ?? lhs.startedAt, rhs.lastActive ?? rhs.startedAt) {
            case let (left?, right?) where left != right:
                left > right
            case (_?, nil):
                true
            case (nil, _?):
                false
            default:
                lhs.id < rhs.id
            }
        }
    }

    /// Loads the first page and replaces the list. Ignored while a request is running.
    public func reload() async {
        guard !isLoading else { return }
        state = .loading
        do {
            let page = try await source.listSessions(limit: Self.pageSize, offset: 0)
            sessions = page.sessions
            windowOffset = page.sessions.filter { !$0.pinned }.count
            hasMore = page.hasMore
            state = .loaded
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(HermesAPIError.from(error))
        }
    }

    /// Appends the next page, if the instance reported one. Sessions already listed are not repeated.
    public func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        state = .loading
        do {
            let page = try await source.listSessions(limit: Self.pageSize, offset: windowOffset)
            let known = Set(sessions.map(\.id))
            sessions += page.sessions.filter { !known.contains($0.id) }
            windowOffset += page.sessions.filter { !$0.pinned }.count
            hasMore = page.hasMore
            state = .loaded
        } catch is CancellationError {
            state = .loaded
        } catch {
            state = .failed(HermesAPIError.from(error))
        }
    }

    /// Creates an empty session on the instance and puts it at the top of the list.
    /// `model` is locked on the session; `nil` lets the instance pick its default model.
    public func create(model: ModelChoice?) async throws -> RemoteSession {
        let session = try await source.createSession(model: model?.model, provider: model?.provider)
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        return session
    }

    /// Renames a session on the instance, then updates its row. A blank title is ignored.
    public func rename(_ sessionID: String, to title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let renamed = try await source.renameSession(sessionID: sessionID, title: trimmed)
        replace(sessionID, with: renamed)
    }

    /// Deletes a session on the instance, then removes its row.
    public func delete(_ sessionID: String) async throws {
        try await source.deleteSession(sessionID: sessionID)
        sessions.removeAll { $0.id == sessionID }
    }

    /// The messages of one session, loaded on demand by the conversation screen. When the transcript moves
    /// to a fork to accept a message, the fork takes the original's row.
    ///
    /// `model` is the model the session was created with in the app, provider included. Without it, the
    /// transcript shows the model the instance lists for the session.
    public func transcript(for session: RemoteSession, model: ModelChoice? = nil) -> RemoteTranscript {
        let transcript = RemoteTranscript(
            sessionID: session.id,
            title: session.title,
            model: model ?? session.model.map { ModelChoice(model: $0) },
            source: source,
            acceptsMessages: session.acceptsAPIMessages,
            storedImages: storedImages
        )
        transcript.onFork = { [weak self] fork in
            self?.replace(session.id, with: fork)
        }
        return transcript
    }

    /// Puts `session` in place of the row with id `originalID`, or at the top if that row is gone.
    func replace(_ originalID: String, with session: RemoteSession) {
        sessions.removeAll { $0.id == session.id && $0.id != originalID }
        if let index = sessions.firstIndex(where: { $0.id == originalID }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }
}
