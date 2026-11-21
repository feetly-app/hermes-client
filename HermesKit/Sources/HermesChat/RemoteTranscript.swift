import Foundation
import HermesAPI

#if !os(Linux)
    import Observation
#endif

/// One message of a transcript: a user or assistant message, ready to show.
public struct TranscriptLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let date: Date?
    /// The images of the message that this device has a copy of, see `SentImageStore`.
    public let images: [ImageAttachment]
    /// Images the message names but this device has no copy of: they were sent from elsewhere.
    public let missingImageCount: Int
    /// Set when the instance wrote the line itself, such as the results of a background task handed to the
    /// agent: a short label to show instead of a user message. `text` keeps the full content.
    public let notice: String?

    public init(
        id: String,
        role: String,
        text: String,
        date: Date?,
        images: [ImageAttachment] = [],
        missingImageCount: Int = 0,
        notice: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.images = images
        self.missingImageCount = missingImageCount
        self.notice = notice
    }
}

/// A conversation: the messages of a session stored on the Hermes instance, and a way to continue it.
///
/// Only user and assistant messages with text or images are kept. Tool, system and compaction rows, and
/// rows the instance marks as hidden, are dropped. The first page holds the newest messages; each further
/// page holds older ones and is put above the lines already shown. Pages are requested with an offset
/// counted in received messages, not in displayed lines.
///
/// `send(_:images:)` posts a message to the session and shows the reply as it streams. Its lines live only
/// in this object until the transcript is loaded again.
///
/// The instance refuses API messages in a session created elsewhere (web dashboard, TUI). For such a
/// session the first `send(_:images:)` forks it into an API session, which holds the same messages, and
/// the transcript continues in the fork: `activeSessionID` changes, `sessionID` does not.
///
/// `@Observable` is applied on Apple platforms, see `RemoteSessionList` for why it is left out on Linux.
@MainActor
#if !os(Linux)
    @Observable
#endif
public final class RemoteTranscript: Identifiable {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(HermesAPIError)
    }

    /// Page size requested from the instance.
    public static let pageSize = 200
    /// Most images one message can carry.
    public static let maxImagesPerMessage = 4

    /// The session this transcript was opened on. Stays the same after a fork.
    public nonisolated let sessionID: String
    /// The title of the session. It changes when the instance names a new session or the user renames it.
    public private(set) var title: String?
    /// The model the session runs on, or `nil` when the instance does not say.
    public nonisolated let model: ModelChoice?
    /// The session that messages are read from and sent to: `sessionID`, or its fork once one was made.
    public private(set) var activeSessionID: String
    /// `false` while the active session refuses API messages: the next `send(_:images:)` forks it first.
    public private(set) var acceptsMessages: Bool
    /// Called on the main actor with the new session after a fork.
    var onFork: (@MainActor (RemoteSession) -> Void)?
    /// Called on the main actor when a reply stops streaming, whatever the outcome. The instance may have
    /// named the session meanwhile.
    var onReplyEnded: (@MainActor () -> Void)?
    public private(set) var lines: [TranscriptLine] = []
    public private(set) var state: State = .idle
    public private(set) var hasMore = false
    /// `true` while a reply is streaming.
    public private(set) var isSending = false
    /// `true` once a message was sent from this transcript.
    public private(set) var hasSent = false
    /// Why the last message got no reply, or `nil`.
    public private(set) var sendError: String?

    private let source: any SessionListing
    /// Copies of the images sent from this device, matched with the images the messages name.
    private let imageStore: (any SentImageStore)?
    /// Messages received so far, displayed or not: the offset of the next page.
    private var received = 0
    private var sendTask: Task<Void, Never>?
    /// The page request in flight, shared by every caller of `load()` and `loadMore()`.
    private var loadTask: Task<Void, Never>?

    public init(
        sessionID: String,
        title: String?,
        model: ModelChoice? = nil,
        source: any SessionListing,
        acceptsMessages: Bool = true,
        imageStore: (any SentImageStore)? = nil
    ) {
        self.imageStore = imageStore
        self.sessionID = sessionID
        self.title = title
        self.model = model
        self.source = source
        self.activeSessionID = sessionID
        self.acceptsMessages = acceptsMessages
    }

    public nonisolated var id: String { sessionID }

    /// Takes the title of `session` when it is the active session and has one.
    public func update(from session: RemoteSession) {
        guard session.id == activeSessionID, let newTitle = session.title, !newTitle.isEmpty else { return }
        title = newTitle
    }

    /// Marks a session just created in the app: there is nothing to load.
    func markEmpty() {
        state = .loaded
    }

    /// Keeps the lines a reader should see, in the order the instance returned them. The image markers the
    /// instance writes into a message are taken out of its text; the images they name are looked up in
    /// `imageStore`. Rows the instance wrote itself in the user's place become notices, see `notice(for:)`.
    public static func lines(
        from messages: [SessionMessage],
        imageStore: (any SentImageStore)? = nil
    ) -> [TranscriptLine] {
        messages.compactMap { message in
            guard message.displayKind != "hidden",
                  message.role == "user" || message.role == "assistant"
            else { return nil }
            if let notice = notice(for: message) {
                return TranscriptLine(
                    id: message.id, role: message.role, text: message.content ?? "", date: message.timestamp,
                    notice: notice
                )
            }
            let content = message.displayContent ?? message.content ?? ""
            let (text, references) = StoredImageMarkers.parse(content)
            let images = references.compactMap { reference in
                reference.sha256.flatMap { imageStore?.image(sha256: $0) }
            }
            guard !text.isEmpty || !references.isEmpty else { return nil }
            return TranscriptLine(
                id: message.id,
                role: message.role,
                text: text,
                date: message.timestamp,
                images: images,
                missingImageCount: references.count - images.count
            )
        }
    }

    /// The label of a user row the instance wrote itself, or `nil` for a message the user wrote.
    ///
    /// When a background task ends, the instance hands its results to the agent as a user message. The row
    /// is typed by its `display_kind`. Rows stored before the instance typed them are recognised by the
    /// header the instance puts at the start of their text.
    static func notice(for message: SessionMessage) -> String? {
        guard message.role == "user" else { return nil }
        let metadata = message.displayMetadata
        let content = message.content ?? ""
        switch message.displayKind {
        case "async_delegation_complete":
            return delegationNotice(content: content, metadata: metadata)
        case "process_complete":
            return metadata?.displayText ?? "Background process finished"
        case nil, "":
            if content.hasPrefix("[ASYNC DELEGATION ") {
                return delegationNotice(content: content, metadata: metadata)
            }
            if content.hasPrefix("[IMPORTANT: Background process ") {
                return "Background process finished"
            }
            return nil
        default:
            return nil
        }
    }

    private static func delegationNotice(content: String, metadata: DisplayMetadata?) -> String {
        if let text = metadata?.displayText {
            return text
        }
        if content.hasPrefix("[ASYNC DELEGATION TASK FAILED") {
            return "A background task failed"
        }
        // The messages endpoint does not return `display_metadata`: the header line says how many tasks ran,
        // as in "— 2 subagent(s) — has finished".
        let count = metadata?.taskCount ?? subagentCount(in: content) ?? 1
        var label = count == 1 ? "Background task finished" : "\(count) background tasks finished"
        if let failed = metadata?.failedCount, failed > 0 {
            label += ", \(failed) failed"
        } else if metadata?.failedCount == nil, content.contains("--- ERROR ---") || content.contains("status=failed") {
            label += " with errors"
        }
        return label
    }

    /// The number in "N subagent(s)" in the first lines of a delegation result, or `nil`.
    private static func subagentCount(in content: String) -> Int? {
        let head = content.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false).prefix(3)
        for line in head {
            guard let range = line.range(of: " subagent(s)") else { continue }
            let digits = line[..<range.lowerBound].reversed().prefix { $0.isNumber }
            if let count = Int(String(digits.reversed())) {
                return count
            }
        }
        return nil
    }

    /// Loads the first page and replaces the transcript. A call made while a page is loading waits for it.
    ///
    /// The request runs in a task this object owns, so cancelling the caller does not cancel it. On iOS 27
    /// a collapsed split view can send the detail view `onDisappear` right after it appears, which cancels
    /// the view's `.task`: the request must outlive it, or the transcript stays empty.
    public func load() async {
        await run { transcript in
            let page = try await transcript.source.listSessionMessages(
                sessionID: transcript.activeSessionID, limit: Self.pageSize, offset: 0
            )
            transcript.lines = Self.lines(from: page.messages, imageStore: transcript.imageStore)
            transcript.received = page.messages.count
            transcript.hasMore = page.hasMore
        }
    }

    /// Prepends the next page of older messages, if the instance reported one. A call made while a page
    /// is loading waits for it.
    public func loadMore() async {
        guard hasMore || loadTask != nil else { return }
        await run { transcript in
            guard transcript.hasMore else { return }
            let page = try await transcript.source.listSessionMessages(
                sessionID: transcript.activeSessionID, limit: Self.pageSize, offset: transcript.received
            )
            transcript.lines = Self.lines(from: page.messages, imageStore: transcript.imageStore) + transcript.lines
            transcript.received += page.messages.count
            transcript.hasMore = page.hasMore
        }
    }

    /// Runs one page request in a task owned by this object, or waits for the one already running.
    private func run(_ request: @escaping @MainActor (RemoteTranscript) async throws -> Void) async {
        if let loadTask {
            await loadTask.value
            return
        }
        state = .loading
        let task = Task { @MainActor in
            do {
                try await request(self)
                self.state = .loaded
            } catch is CancellationError {
                self.state = self.lines.isEmpty ? .idle : .loaded
            } catch {
                self.state = .failed(HermesAPIError.from(error))
            }
            self.loadTask = nil
        }
        loadTask = task
        await task.value
    }

    /// Sends a message, with its images, to the session and shows the reply as it streams. The user line
    /// appears at once. A message with neither text nor images is ignored, and so is a call made while a
    /// reply is still streaming. Images past `maxImagesPerMessage` are dropped. Images sent are copied to the
    /// image store, so the transcript can show them once it is loaded again.
    public func send(_ text: String, images: [ImageAttachment] = []) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = Array(images.prefix(Self.maxImagesPerMessage))
        guard !message.isEmpty || !images.isEmpty, !isSending else { return }
        isSending = true
        hasSent = true
        sendError = nil
        images.forEach { imageStore?.save($0) }
        lines.append(
            TranscriptLine(
                id: "local-user-\(UUID().uuidString)", role: "user", text: message, date: Date(), images: images
            )
        )
        let replyID = "local-assistant-\(UUID().uuidString)"
        lines.append(TranscriptLine(id: replyID, role: "assistant", text: "", date: nil))

        let task = Task { await self.stream(message, images: images, replyID: replyID) }
        sendTask = task
        await task.value
        sendTask = nil
        isSending = false
        onReplyEnded?()
    }

    /// Stops the reply being streamed. The text received so far stays in the transcript.
    public func stop() {
        sendTask?.cancel()
    }

    /// Forks the active session so that it accepts API messages. Returns `false`, with `sendError` set,
    /// if the fork failed or was cancelled.
    private func forkIfNeeded() async -> Bool {
        guard !acceptsMessages else { return true }
        do {
            let fork = try await source.forkSession(sessionID: activeSessionID)
            activeSessionID = fork.id
            acceptsMessages = true
            onFork?(fork)
            return true
        } catch is CancellationError {
            return false
        } catch {
            let reason = HermesAPIError.from(error).errorDescription ?? "The request failed."
            sendError = "This conversation was started outside the app and could not be continued here. \(reason)"
            return false
        }
    }

    private func stream(_ message: String, images: [ImageAttachment], replyID: String) async {
        guard await forkIfNeeded() else {
            lines.removeAll { $0.id == replyID }
            return
        }
        do {
            let events = await source.streamSessionChat(sessionID: activeSessionID, message: message, images: images)
            for try await event in events {
                switch event {
                case .delta(let delta):
                    setReply(id: replyID) { $0 + delta }
                case .completed(let content):
                    if !content.isEmpty {
                        setReply(id: replyID) { _ in content }
                    }
                case .failed(let reason):
                    sendError = reason
                case .finished:
                    break
                }
            }
        } catch is CancellationError {
            // Stopped by the user: keep what was received.
        } catch {
            sendError = HermesAPIError.from(error).errorDescription ?? "The message could not be sent."
        }
        if let index = lines.firstIndex(where: { $0.id == replyID }), lines[index].text.isEmpty {
            lines.remove(at: index)
        }
    }

    private func setReply(id: String, _ update: (String) -> String) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        let line = lines[index]
        lines[index] = TranscriptLine(
            id: line.id, role: line.role, text: update(line.text), date: line.date,
            images: line.images, missingImageCount: line.missingImageCount, notice: line.notice
        )
    }
}
