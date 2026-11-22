import HermesAPI
import HermesChat
import PhotosUI
import SwiftUI

/// A conversation: a session stored on the Hermes instance. Shows its messages, with the floating composer
/// over their bottom; a message, with its photos, streams the reply in from the instance.
/// A session created outside the app is forked on the first message, see `RemoteTranscript`.
struct ChatView: View {
    let transcript: RemoteTranscript

    @State private var draft = ""
    @State private var isAddingImages = false
    /// The photos picked in the add sheet. `pending` follows it.
    @State private var pickerItems: [PhotosPickerItem] = []
    /// Ids of the photos taken with the camera, in the order taken. They are not part of the picker selection.
    @State private var cameraIDs: [String] = []
    @State private var pending = PendingAttachments<String>()
    /// Where the transcript is scrolled. While the reader scrolls it holds the id of the line at the top of
    /// the viewport; set it to scroll there, or to the end.
    @State private var position = ScrollPosition(idType: String.self)
    /// Further tries left for a scroll to the end, checked when the scroll stops: lines not laid out yet
    /// have estimated heights, so the first scroll can stop short.
    @State private var endRetries = 0
    /// Set when the reader stops on the oldest shown line; cleared once the older page is in place.
    @State private var loadingOlder = false
    @FocusState private var isComposerFocused: Bool
    /// `false` while the reader is scrolled away from the newest line: shows the scroll-to-bottom button.
    @State private var isAtBottom = true
    /// Top of the composer inset on screen: the visible part of the transcript ends there.
    @State private var composerTop = CGFloat.greatestFiniteMagnitude

    var body: some View {
        VStack(spacing: 0) {
            statusView

            // `defaultScrollAnchor(.bottom)` and `ScrollViewProxy.scrollTo` are not used: with a lazy stack on
            // iOS 27 the first leaves the viewport blank until the user scrolls, and the second does nothing
            // after a prepend. The scroll position is driven through `scrollPosition(_:anchor:)` instead.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(transcript.lines) { line in
                        if let notice = line.notice {
                            NoticeRow(label: notice, details: line.text)
                        } else {
                            MessageRow(line: line)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding()

                ScrollBottomMarker(visibleEnd: composerTop, isAtBottom: $isAtBottom) {
                    scrollToEnd(animation: .smooth(duration: 0.25))
                }
            }
            // Before the inset, so a tap on the composer does not hide the keyboard.
            .dismissesKeyboard($isComposerFocused)
            .scrollPosition($position, anchor: .top)
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting:
                    // The reader took over: a scroll to the end under way is not finished.
                    endRetries = 0
                case .idle:
                    // A scroll to the end that stopped short goes on from there.
                    if endRetries > 0 {
                        if isAtBottom {
                            endRetries = 0
                        } else {
                            endRetries -= 1
                            scrollToEnd(animation: .smooth(duration: 0.2))
                        }
                    }
                    // Stopping on the oldest shown line pulls in the next older page.
                    if !loadingOlder, transcript.hasMore, transcript.state == .loaded,
                       let topID = position.viewID(type: String.self), topID == transcript.lines.first?.id
                    {
                        loadingOlder = true
                    }
                default:
                    break
                }
            }
            .task(id: loadingOlder) {
                guard loadingOlder else { return }
                let firstShown = position.viewID(type: String.self)
                await transcript.loadMore()
                // Older lines went above: put the line the reader was on back at the top.
                if let firstShown {
                    position.scrollTo(id: firstShown, anchor: .top)
                }
                loadingOlder = false
            }
            // A message sent from here scrolls the transcript to its end.
            .onChange(of: transcript.lines.last?.id) { oldID, lastID in
                if oldID != nil, lastID != nil {
                    endRetries = 2
                    scrollToEnd(animation: .default)
                }
            }
            // A step of the reply being streamed makes its line taller. The lazy stack can stop drawing its rows
            // when a line grows under a scroll to the end, leaving the viewport blank: the scroll is asked again,
            // which also keeps the newest step in view while the reader follows the end.
            .onChange(of: transcript.lines.last?.steps.count) { _, _ in
                if transcript.isSending, isAtBottom || endRetries > 0 {
                    endRetries = max(endRetries, 1)
                    scrollToEnd(animation: nil)
                }
            }
            // The lines scroll beneath the composer.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerArea
            }
        }
        .navigationTitle(transcript.title ?? ConversationTitle.placeholder)
        .inlineNavigationTitle()
        .sheet(isPresented: $isAddingImages) {
            AddToMessageSheet(
                selection: $pickerItems,
                maxSelectionCount: max(1, RemoteTranscript.maxImagesPerMessage - cameraIDs.count),
                canAddPhoto: pending.entries.count < RemoteTranscript.maxImagesPerMessage,
                onPhotoTaken: addCameraPhoto
            )
        }
        .onChange(of: pickerItems) { _, items in
            loadPicked(items)
        }
        // The browser starts the load when the session opens; this waits for it, or loads again if it was
        // never started. On iOS 27 a collapsed split view can skip or cancel this task, so the jump to the
        // newest line also runs when the first load lands.
        .task(id: transcript.sessionID) {
            if transcript.state != .loaded {
                await transcript.load()
            }
            await scrollToNewest()
        }
        .onChange(of: transcript.state) { oldState, newState in
            if oldState == .loading, newState == .loaded, position.viewID == nil, position.edge == nil {
                Task { await scrollToNewest() }
            }
        }
    }
}

private extension ChatView {
    var composerArea: some View {
        VStack(spacing: 8) {
            // A session created elsewhere (web dashboard, TUI) is forked on the first message.
            if !transcript.acceptsMessages {
                ComposerStatus {
                    Text("Started outside the app. Your next message continues it as a new conversation.")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = transcript.sendError {
                ComposerStatus {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            ChatComposer(
                draft: $draft,
                isFocused: $isComposerFocused,
                pendingImages: pending.attachments,
                onRemoveImage: removeImage,
                onAdd: { isAddingImages = true },
                isBusy: transcript.isSending,
                canSend: canSend,
                onSend: send,
                onStop: { transcript.stop() }
            )
        }
        .reportsTop($composerTop)
        .scrollToBottomButton(isVisible: !isAtBottom) {
            endRetries = 2
            scrollToEnd(animation: .smooth(duration: 0.35))
        }
    }

    var canSend: Bool {
        !pending.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        let text = draft
        let images = pending.attachments
        draft = ""
        pending.clear()
        pickerItems = []
        cameraIDs = []
        Task { await transcript.send(text, images: images) }
    }

    /// Everything the composer should hold: the picked photos, then the camera photos.
    func selectedIDs(_ items: [PhotosPickerItem]) -> [String] {
        // The shared photo library gives every item an identifier.
        items.compactMap(\.itemIdentifier) + cameraIDs
    }

    /// Loads the newly picked photos into the composer and drops the deselected ones.
    func loadPicked(_ items: [PhotosPickerItem]) {
        // Camera photos count against the limit too: trim the picks that do not fit.
        let room = RemoteTranscript.maxImagesPerMessage - cameraIDs.count
        if items.count > room {
            pickerItems = Array(items.prefix(max(0, room)))
            return
        }
        let toLoad = pending.select(selectedIDs(items))
        for item in items {
            guard let id = item.itemIdentifier, toLoad.contains(id) else { continue }
            Task {
                let attachment = await ImageAttachmentLoader.attachment(from: item)
                pending.finishLoading(id, attachment: attachment)
            }
        }
    }

    /// Adds a photo taken with the camera, downscaled like a picked one.
    func addCameraPhoto(_ data: Data) {
        guard pending.entries.count < RemoteTranscript.maxImagesPerMessage,
              let attachment = ImageAttachmentLoader.jpegAttachment(from: data)
        else { return }
        let id = "camera-\(UUID().uuidString)"
        cameraIDs.append(id)
        _ = pending.select(selectedIDs(pickerItems))
        pending.finishLoading(id, attachment: attachment)
    }

    func removeImage(at index: Int) {
        let id = pending.entries[index].id
        cameraIDs.removeAll { $0 == id }
        let remaining = Set(pending.remove(id))
        pickerItems.removeAll { $0.itemIdentifier.map { !remaining.contains($0) } ?? true }
    }

    /// Scrolls to the end of the transcript in one move, so it can be animated: the bottom of the newest
    /// line comes just above the composer, however tall the line is.
    ///
    /// Setting the position to the value it already holds does nothing. After a scroll to the bottom edge
    /// that the reader has not moved from, the bottom of the last line is asked for instead.
    func scrollToEnd(animation: Animation?) {
        guard let lastID = transcript.lines.last?.id else { return }
        var target = position
        if target.edge == .bottom {
            target.scrollTo(id: lastID, anchor: .bottom)
        } else {
            target.scrollTo(edge: .bottom)
        }
        withAnimation(animation) {
            position = target
        }
    }

    /// Opens the transcript on its newest line. The lazy stack estimates the height of rows it has not
    /// laid out yet, so the first jump can stop short: the end is asked for twice more, each time with a
    /// different value so the position changes.
    func scrollToNewest() async {
        guard let lastID = transcript.lines.last?.id else { return }
        position.scrollTo(id: lastID, anchor: .top)
        try? await Task.sleep(for: .milliseconds(10))
        position.scrollTo(edge: .bottom)
        try? await Task.sleep(for: .milliseconds(10))
        position.scrollTo(id: lastID, anchor: .bottom)
    }

    /// Loading and failure state, above the transcript.
    @ViewBuilder
    var statusView: some View {
        switch transcript.state {
        case .idle, .loaded:
            EmptyView()
        case .loading:
            ProgressView()
                .padding(.vertical, 8)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task {
                        await transcript.load()
                        await scrollToNewest()
                    }
                }
            }
            .padding()
        }
    }
}

/// One message of a conversation. A reply is laid out straight on the page, full width, without a
/// background; a message from the user sits in a rounded bubble on the right, with its images above it.
struct MessageRow: View {
    let line: TranscriptLine

    private var isUser: Bool { line.role == "user" }

    var body: some View {
        if isUser {
            VStack(alignment: .trailing, spacing: 6) {
                images
                if !line.text.isEmpty {
                    Text(line.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.primary.opacity(0.12), in: .rect(cornerRadius: 22, style: .continuous))
                }
            }
            .padding(.leading, 40)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // The tools the agent ran: a line of their own, or above the text of a reply being streamed.
                if !line.steps.isEmpty {
                    ActivityView(steps: line.steps)
                        .padding(.bottom, line.text.isEmpty ? 0 : 18)
                }
                images
                MarkdownView(source: line.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var images: some View {
        if !line.images.isEmpty || line.missingImageCount > 0 {
            MessageImages(
                images: line.images,
                missingCount: line.missingImageCount,
                alignment: isUser ? .trailing : .leading
            )
        }
    }
}

/// A line the instance wrote in the user's place, such as the results of a background task handed to the
/// agent: a short label rather than a user message. A tap shows the full text.
struct NoticeRow: View {
    let label: String
    let details: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(label)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the details" : "Shows the details")

            if isExpanded, !details.isEmpty {
                MarkdownView(source: details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 2)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
