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
    func getSession(sessionID: String) async throws -> RemoteSession
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
    /// Sessions fetched by id because the loaded pages did not hold them (see `fetchMissing(_:)`).
    private var fetchedSessions: [String: RemoteSession] = [:]
    /// Ids the instance answered `404` for.
    private var orphanIDs: Set<String> = []
    private var fetchingIDs: Set<String> = []
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
        Self.recentFirst(sessions)
    }

    /// The known sessions with these ids, most recent activity first: from the loaded pages, or fetched one
    /// by one with `fetchMissing(_:)`. Ids not known yet, and orphans (sessions gone from the instance), are
    /// left out.
    public func sessions(withIDs ids: [String]) -> [RemoteSession] {
        let wanted = Set(ids)
        var found = sessions.filter { wanted.contains($0.id) }
        let listed = Set(found.map(\.id))
        found += wanted.subtracting(listed).compactMap { fetchedSessions[$0] }
        return Self.recentFirst(found)
    }

    /// `true` when every one of these ids is known or an orphan: nothing is left to fetch.
    public func knowsAll(_ ids: [String]) -> Bool {
        ids.allSatisfy { isKnown($0) || orphanIDs.contains($0) }
    }

    /// Fetches, one request each, the sessions with these ids that the loaded pages do not hold. A session the
    /// instance no longer has (`404`) is an orphan and is not asked for again; other failures are retried on
    /// the next call.
    public func fetchMissing(_ ids: [String]) async {
        let missing = Set(ids).filter { !isKnown($0) && !orphanIDs.contains($0) && !fetchingIDs.contains($0) }
        guard !missing.isEmpty else { return }
        fetchingIDs.formUnion(missing)
        defer { fetchingIDs.subtract(missing) }
        let source = source
        let results = await withTaskGroup(of: (String, FetchResult).self) { group in
            for id in missing {
                group.addTask {
                    do {
                        return (id, .found(try await source.getSession(sessionID: id)))
                    } catch let error as HermesAPIError where error == .notFound {
                        return (id, .gone)
                    } catch {
                        return (id, .failed)
                    }
                }
            }
            var results: [(String, FetchResult)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        for (id, result) in results {
            switch result {
            case .found(let session):
                fetchedSessions[id] = session
            case .gone:
                orphanIDs.insert(id)
            case .failed:
                break
            }
        }
    }

    private enum FetchResult: Sendable {
        case found(RemoteSession)
        case gone
        case failed
    }

    private func isKnown(_ id: String) -> Bool {
        fetchedSessions[id] != nil || sessions.contains { $0.id == id }
    }

    private static func recentFirst(_ sessions: [RemoteSession]) -> [RemoteSession] {
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
        fetchedSessions[sessionID] = nil
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
        fetchedSessions[originalID] = nil
        fetchedSessions[session.id] = nil
        sessions.removeAll { $0.id == session.id && $0.id != originalID }
        if let index = sessions.firstIndex(where: { $0.id == originalID }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }
}
