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
    /// The images of the message: the ones just sent from here, or the ones a stored message names, which
    /// `StoredImageLoader` gets back through the sidecar.
    public let images: [MessageImage]
    /// Set when the instance wrote the line itself, such as the results of a background task handed to the
    /// agent: a short label to show instead of a user message. `text` keeps the full content.
    public let notice: String?
    /// The tools the agent ran and its reasoning, in order. Stored messages put them on lines of their own,
    /// with no text; a reply being streamed carries its steps above its text.
    public var steps: [ActivityStep]
    /// `true` while the message is waiting in queue for earlier turns to finish.
    public var isQueued: Bool

    public init(
        id: String,
        role: String,
        text: String,
        date: Date?,
        images: [MessageImage] = [],
        notice: String? = nil,
        steps: [ActivityStep] = [],
        isQueued: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.images = images
        self.notice = notice
        self.steps = steps
        self.isQueued = isQueued
    }

    /// `true` for a line that only shows what the agent did, with no message text.
    public var isActivity: Bool { !steps.isEmpty && text.isEmpty && images.isEmpty }
}

/// A conversation: the messages of a session stored on the Hermes instance, and a way to continue it.
///
/// User and assistant messages with text or images are kept. The tools an assistant row calls, the results
/// of the `tool` rows that answer them and the model's reasoning become activity lines, see `ActivityStep`.
/// System and compaction rows, and rows the instance marks as hidden, are dropped. The first page holds the newest messages; each further
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
/// With a sidecar, messages go through it (`POST {sidecar}/sessions/{id}/chat/stream`), which runs the turn in
/// the background, and `load()` attaches to a turn still running so that its reply shows live.
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
    /// Called on the main actor when the streaming state changes.
    var onStreamingChanged: (@MainActor (Bool) -> Void)?
    public private(set) var lines: [TranscriptLine] = []
    public private(set) var state: State = .idle
    public private(set) var hasMore = false
    /// `true` while a reply is streaming.
    public private(set) var isSending = false
    /// `true` once a message was sent from this transcript.
    public private(set) var hasSent = false
    /// Why the last message got no reply, or `nil`.
    public private(set) var sendError: String?

    /// Loads the images stored messages name, or `nil` without a sidecar: they then show as not available.
    public nonisolated let storedImages: StoredImageLoader?
    private let source: any SessionListing
    /// The sidecar's stream endpoints, or `nil` without a sidecar: messages then go to the instance directly,
    /// and a turn already running cannot be followed.
    private let sidecar: (any TurnStreaming)?
    /// Messages received so far, displayed or not: the offset of the next page.
    private var received = 0
    private var sendTask: Task<Void, Never>?
    /// The page request in flight, shared by every caller of `load()` and `loadMore()`.
    private var loadTask: Task<Void, Never>?
    /// Follows a turn attached to by `load()`, until its reply ended and was cleaned up.
    private(set) var attachTask: Task<Void, Never>?

    private struct QueuedTurn: Sendable {
        let lineID: String
        let message: String
        let images: [ImageAttachment]
    }

    private var sendQueue: [QueuedTurn] = []

    /// Whether there are messages waiting in queue to be sent.
    public var hasQueuedMessages: Bool {
        !sendQueue.isEmpty
    }

    /// With a `sidecar`, messages are sent through it, and `load()` attaches to a turn already running.
    public init(
        sessionID: String,
        title: String?,
        model: ModelChoice? = nil,
        source: any SessionListing,
        acceptsMessages: Bool = true,
        storedImages: StoredImageLoader? = nil,
        sidecar: (any TurnStreaming)? = nil
    ) {
        self.storedImages = storedImages
        self.sessionID = sessionID
        self.title = title
        self.model = model
        self.source = source
        self.sidecar = sidecar
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
    /// instance writes into a message are taken out of its text and become `.stored` images. Rows the instance wrote itself in the user's place become notices, see `notice(for:)`.
    public static func lines(from messages: [SessionMessage]) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        /// Index in `lines` of the activity line still taking steps, if any.
        var openActivity: Int?
        /// Where each tool call sits, to put its result in place: line index, step index.
        var callPositions: [String: (line: Int, step: Int)] = [:]

        func append(_ step: ActivityStep, startingAt rowID: String) -> Int {
            if let index = openActivity {
                lines[index].steps.append(step)
                return index
            }
            lines.append(TranscriptLine(id: "activity-\(rowID)", role: "assistant", text: "", date: nil, steps: [step]))
            openActivity = lines.count - 1
            return lines.count - 1
        }

        for message in messages where message.displayKind != "hidden" {
            switch message.role {
            case "tool":
                guard let callID = message.toolCallID, let position = callPositions[callID] else { continue }
                var step = lines[position.line].steps[position.step]
                step.result = message.content
                step.status = ActivityStep.status(forResult: message.content, arguments: step.argumentObject)
                lines[position.line].steps[position.step] = step
            case "assistant":
                if let reasoning = message.reasoning {
                    _ = append(.thinking(id: "thinking-\(message.id)", text: reasoning), startingAt: message.id)
                }
                if let line = messageLine(message) {
                    openActivity = nil
                    lines.append(line)
                }
                for call in message.toolCalls {
                    let step = ActivityStep(id: call.id, name: call.name, arguments: call.arguments)
                    let index = append(step, startingAt: message.id)
                    callPositions[call.id] = (index, lines[index].steps.count - 1)
                }
            case "user":
                openActivity = nil
                if let notice = notice(for: message) {
                    lines.append(
                        TranscriptLine(
                            id: message.id, role: message.role, text: message.content ?? "", date: message.timestamp,
                            notice: notice
                        )
                    )
                } else if let line = messageLine(message) {
                    lines.append(line)
                }
            default:
                continue
            }
        }
        return lines
    }

    /// The text and images of a user or assistant row, or `nil` when it has neither.
    private static func messageLine(_ message: SessionMessage) -> TranscriptLine? {
        let content = message.displayContent ?? steerText(of: message) ?? message.content ?? ""
        let (text, references) = StoredImageMarkers.parse(content)
        guard !text.isEmpty || !references.isEmpty else { return nil }
        return TranscriptLine(
            id: message.id,
            role: message.role,
            text: text,
            date: message.timestamp,
            images: references.map { .stored(sha256: $0.sha256) },
            isQueued: message.displayKind == "queued"
        )
    }

    /// The user's words in a message sent while a reply was running (`display_kind` `steer`), or `nil`.
    ///
    /// The instance stores such a message wrapped in a notice for the model and does not send the plain text
    /// with it: the words sit between the end of the opening `[OUT-OF-BAND USER MESSAGE …]` line and the
    /// closing `[/OUT-OF-BAND USER MESSAGE]`, as the instance itself reads them back.
    static func steerText(of message: SessionMessage) -> String? {
        guard message.role == "user", message.displayKind == "steer", let content = message.content,
              let open = content.range(of: "[OUT-OF-BAND USER MESSAGE"),
              let lineEnd = content[open.upperBound...].firstIndex(of: "\n"),
              let close = content.range(of: "[/OUT-OF-BAND USER MESSAGE]", range: lineEnd..<content.endIndex)
        else { return nil }
        let text = content[content.index(after: lineEnd)..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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
    ///
    /// With a sidecar, a turn of the session still running (sent from another device, or before the app
    /// left) is then attached to: its reply shows as it streams, from the events the sidecar buffered, and
    /// `isSending` stays `true` until it ends. `load()` does not wait for it.
    public func load() async {
        await run { transcript in
            let page = try await transcript.source.listSessionMessages(
                sessionID: transcript.activeSessionID, limit: Self.pageSize, offset: 0
            )
            // A reply streaming meanwhile is not in the page yet: its lines stay below it.
            let live = transcript.isSending ? transcript.lines.filter { $0.id.hasPrefix("local-") } : []
            transcript.lines = Self.lines(from: page.messages) + live
            transcript.received = page.messages.count
            transcript.hasMore = page.hasMore
            // The page shows at once, without waiting for the status check.
            transcript.state = .loaded
            await transcript.attachIfRunning()
        }
    }

    /// Attaches to the turn the sidecar runs in the active session, if any. A failed status check is not an
    /// error: the transcript then shows what the instance stored.
    private func attachIfRunning() async {
        guard let sidecar, !isSending else { return }
        let sessionID = activeSessionID
        guard let status = try? await sidecar.activeStreamStatus(sessionID: sessionID), status.isActive,
              !isSending, sessionID == activeSessionID
        else { return }
        isSending = true
        onStreamingChanged?(true)
        sendError = nil
        let replyID = "local-assistant-\(UUID().uuidString)"
        lines.append(TranscriptLine(id: replyID, role: "assistant", text: "", date: nil))
        let stream = Task {
            await self.consume(await sidecar.attachStream(sessionID: sessionID), replyID: replyID)
        }
        sendTask = stream
        attachTask = Task {
            await stream.value
            if !self.sendQueue.isEmpty && self.sendError == nil && !Task.isCancelled {
                let next = self.sendQueue.removeFirst()
                let task = Task {
                    await self.processSendQueue(
                        initialMessage: next.message, initialImages: next.images, initialLineID: next.lineID
                    )
                }
                self.sendTask = task
                await task.value
            }
            self.sendTask = nil
            self.isSending = false
            self.onStreamingChanged?(false)
            self.attachTask = nil
            self.onReplyEnded?()
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
            transcript.lines = Self.lines(from: page.messages) + transcript.lines
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
    /// appears at once. If a reply is still streaming, the message is queued and sent as soon as the
    /// previous turns finish. A message with neither text nor images is ignored. Images past
    /// `maxImagesPerMessage` are dropped.
    public func send(_ text: String, images: [ImageAttachment] = []) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = Array(images.prefix(Self.maxImagesPerMessage))
        guard !message.isEmpty || !images.isEmpty else { return }

        let userLineID = "local-user-\(UUID().uuidString)"
        let userLine = TranscriptLine(
            id: userLineID, role: "user", text: message, date: Date(),
            images: images.map { .attached($0) },
            isQueued: isSending
        )
        lines.append(userLine)

        if isSending {
            sendQueue.append(QueuedTurn(lineID: userLineID, message: message, images: images))
            return
        }

        isSending = true
        onStreamingChanged?(true)
        hasSent = true
        sendError = nil

        let task = Task {
            await self.processSendQueue(
                initialMessage: message, initialImages: images, initialLineID: userLineID
            )
        }
        sendTask = task
        await task.value
        sendTask = nil
        isSending = false
        onStreamingChanged?(false)
        onReplyEnded?()
    }

    /// Stops the reply being streamed and clears any queued messages. The text received so far stays
    /// in the transcript. Through a sidecar the turn goes on there: this only stops following it.
    public func stop() {
        clearSendQueue()
        sendTask?.cancel()
    }

    private func processSendQueue(
        initialMessage: String, initialImages: [ImageAttachment], initialLineID: String
    ) async {
        var current: (message: String, images: [ImageAttachment], lineID: String)? = (
            initialMessage, initialImages, initialLineID
        )

        while let active = current {
            if let index = lines.firstIndex(where: { $0.id == active.lineID }) {
                lines[index].isQueued = false
            }

            let replyID = "local-assistant-\(UUID().uuidString)"
            let replyLine = TranscriptLine(id: replyID, role: "assistant", text: "", date: nil)
            if let userIndex = lines.firstIndex(where: { $0.id == active.lineID }) {
                lines.insert(replyLine, at: userIndex + 1)
            } else {
                lines.append(replyLine)
            }

            await stream(active.message, images: active.images, replyID: replyID)

            if Task.isCancelled || sendError != nil {
                clearSendQueue()
                break
            }

            if !sendQueue.isEmpty {
                let next = sendQueue.removeFirst()
                current = (next.message, next.images, next.lineID)
            } else {
                current = nil
            }
        }
    }

    private func clearSendQueue() {
        for queued in sendQueue {
            if let index = lines.firstIndex(where: { $0.id == queued.lineID }) {
                lines[index].isQueued = false
            }
        }
        sendQueue.removeAll()
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
        // Through the sidecar the turn runs in the background there, and can be attached to again.
        let events: AsyncThrowingStream<SessionChatEvent, any Error>
        if let sidecar {
            events = await sidecar.streamChat(sessionID: activeSessionID, message: message, images: images)
        } else {
            events = await source.streamSessionChat(sessionID: activeSessionID, message: message, images: images)
        }
        await consume(events, replyID: replyID)
    }

    /// Shows the events of a reply on its line as they arrive, then tidies the line once the stream ends.
    private func consume(_ events: AsyncThrowingStream<SessionChatEvent, any Error>, replyID: String) async {
        do {
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
                case .toolStarted(let name, let preview, let arguments):
                    addStep(
                        ActivityStep(
                            id: "local-step-\(UUID().uuidString)", name: name, arguments: arguments ?? "",
                            preview: preview, status: .running
                        ),
                        to: replyID
                    )
                case .toolFinished(let name, let preview, let failed):
                    finishStep(named: name, result: preview, failed: failed, in: replyID)
                case .thinking(let text):
                    addThinking(text, to: replyID)
                case .finished:
                    break
                }
            }
        } catch is CancellationError {
            // Stopped by the user: keep what was received.
        } catch {
            sendError = HermesAPIError.from(error).errorDescription ?? "The message could not be sent."
        }
        // A tool still marked as running when the reply ends will not report back on this stream.
        updateSteps(of: replyID) { steps in
            for index in steps.indices where steps[index].status == .running {
                steps[index].status = .done
            }
        }
        if let index = lines.firstIndex(where: { $0.id == replyID }), lines[index].text.isEmpty,
           lines[index].steps.isEmpty
        {
            lines.remove(at: index)
        }
    }

    // The live steps of a reply are kept on its own line, above its text. Inserting a separate line while the
    // reply streams makes the lazy transcript lose its scroll position.

    /// Adds a step to the reply being streamed.
    private func addStep(_ step: ActivityStep, to replyID: String) {
        updateSteps(of: replyID) { $0.append(step) }
    }

    /// Reasoning arrives in pieces: they extend the last thinking step, or start a new one.
    private func addThinking(_ text: String, to replyID: String) {
        updateSteps(of: replyID) { steps in
            if let last = steps.indices.last, steps[last].kind == .thinking {
                steps[last].result = (steps[last].result ?? "") + text
            } else {
                steps.append(.thinking(id: "local-thinking-\(UUID().uuidString)", text: text))
            }
        }
    }

    /// Marks the oldest running step of the tool `name` as finished. Live events carry no call id: calls of one
    /// tool finish in the order they started.
    private func finishStep(named name: String, result: String?, failed: Bool, in replyID: String) {
        updateSteps(of: replyID) { steps in
            guard let index = steps.firstIndex(where: { $0.name == name && $0.status == .running }) else { return }
            steps[index].result = result
            steps[index].status = failed
                ? .failed
                : ActivityStep.status(forResult: result, arguments: steps[index].argumentObject)
        }
    }

    private func updateSteps(of lineID: String, _ update: (inout [ActivityStep]) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        update(&lines[index].steps)
    }

    private func setReply(id: String, _ update: (String) -> String) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        let line = lines[index]
        lines[index] = TranscriptLine(
            id: line.id, role: line.role, text: update(line.text), date: line.date,
            images: line.images, notice: line.notice, steps: line.steps, isQueued: line.isQueued
        )
    }
}
