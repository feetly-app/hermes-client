import HermesAPI
import HermesChat
import SwiftUI

/// The message composer floating over the bottom of a conversation: a rounded glass card with the
/// images waiting to be sent, the text field, and the action buttons (add, send or stop).
///
/// Layout mirrors ChatGPT: single-row when the draft fits on one line, then animates to a stacked
/// layout (text full-width on top, button row below) as the user types.
///
/// **Keyboard preservation**: the TextField sits at a fixed structural position inside a VStack
/// that is always present in the layout. The action buttons slide in and out (their frame width
/// animates to/from zero) around it rather than the whole branch being replaced, so SwiftUI never
/// removes and re-creates the TextField across the transition and the keyboard stays up.
///
/// **Expansion detection**: a hidden measurement TextField constrained to the compact width
/// (captured once from the real field's onGeometryChange while !isExpanded) drives `isExpanded`
/// via its height. Using the same compact width for both expand and collapse avoids the feedback
/// loop that occurs if collapse uses the wider full-width height: expanded → text field wider →
/// height shrinks → collapse → narrower → text wraps → expand → …
///
/// Both the local and the remote conversation screens use it. A screen that takes text only passes
/// no `onAdd`, which hides the add button.
struct ChatComposer: View {
    @Binding var draft: String
    /// Focus of the text field: the conversation screen clears it to hide the keyboard.
    var isFocused: FocusState<Bool>.Binding
    /// Images waiting to be sent, shown above the text field.
    var pendingImages: [ImageAttachment] = []
    var onRemoveImage: (Int) -> Void = { _ in }
    /// Opens the add sheet. `nil` hides the add button.
    var onAdd: (() -> Void)?
    let isBusy: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    /// Whether the composer is in the expanded (stacked) layout.
    @State private var isExpanded = false
    /// Height of the measurement probe at exactly one line of text. Captured once on first appear;
    /// expansion triggers when the probe exceeds this by more than 2 pt.
    @State private var singleLineHeight: CGFloat = 0
    /// Actual width of the text field while in compact layout (squeezed between the buttons).
    /// Captured at runtime via onGeometryChange; the hidden measurement probe is constrained to
    /// this width so both expand and collapse use the same reference — no feedback loop.
    @State private var compactTextWidth: CGFloat = 0

    /// Diameter of the round action buttons.
    @ScaledMetric(relativeTo: .subheadline) private var buttonSize: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !pendingImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, image in
                            PendingImageThumbnail(data: image.data) {
                                onRemoveImage(index)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            // The input area uses a fixed structure so the TextField is never removed and
            // re-added during the layout transition (which would dismiss the keyboard).
            //
            // Compact: HStack with buttons visible at full buttonSize width.
            // Expanded: same HStack, buttons animated to width 0 and clipped out; the VStack
            //           below the TextField grows to show the action row.
            //
            // spacing also animates to 0 when buttons collapse so there is no phantom gap.
            HStack(alignment: .bottom, spacing: isExpanded ? 0 : 8) {
                // Add button: always rendered at a stable position; collapses to 0 when expanded.
                if let onAdd {
                    ComposerCircleButton("Add images", systemImage: "plus", size: buttonSize, action: onAdd)
                        .disabled(isBusy)
                        .frame(width: isExpanded ? 0 : buttonSize)
                        .clipped()
                }

                // The TextField is always inside this VStack at child index 0 — never moved,
                // never recreated. Focus (and the keyboard) survive the layout change.
                VStack(alignment: .leading, spacing: 8) {
                    composerTextField
                    if isExpanded {
                        actionRow
                    }
                }

                // Send/stop: collapses to 0 when expanded (also shown in actionRow).
                sendStopButton
                    .frame(width: isExpanded ? 0 : buttonSize)
                    .clipped()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // The measurement probe sits here as a background at the same width as the padded VStack
        // content. Because it is never constrained by buttons, its width is stable regardless of
        // which layout mode is active — no feedback loop is possible.
        .background(alignment: .top) {
            measurementProbe
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.28, bounce: 0.12), value: isExpanded)
    }

    // MARK: - Measurement probe

    /// A hidden, non-interactive copy of the text field constrained to `compactTextWidth`.
    ///
    /// Because its width never changes (it is not affected by which layout mode is active),
    /// its height is a stable signal for both expand and collapse:
    /// - `height > singleLineHeight + 2`  → text would wrap in compact mode → expand
    /// - `height ≤ singleLineHeight + 2`  → text fits on one line in compact mode → collapse
    ///
    /// `singleLineHeight` is set on first appear (draft is empty → one line).
    private var measurementProbe: some View {
        TextField("", text: $draft, axis: .vertical)
            .lineLimit(1 ... 6)
            .textFieldStyle(.plain)
            .padding(.vertical, 7)
            // Constrain to compact width once it is known; fall back to full width on the first
            // layout pass (before compactTextWidth is captured) — acceptable because the
            // single-line height is font-size-dependent, not width-dependent.
            .frame(width: compactTextWidth > 0 ? compactTextWidth : nil, alignment: .leading)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                if singleLineHeight == 0 {
                    singleLineHeight = newHeight
                }
                guard singleLineHeight > 0 else { return }
                isExpanded = newHeight > singleLineHeight + 2
            }
    }

    // MARK: - Sub-views

    @ViewBuilder private var composerTextField: some View {
        TextField("Message", text: $draft, axis: .vertical)
            .focused(isFocused)
            .textFieldStyle(.plain)
            .lineLimit(1 ... 6)
            .padding(.vertical, 7)
            // Capture the compact width while in compact layout so the measurement probe can be
            // constrained to the same reference width for both expand and collapse detection.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in
                if !isExpanded, w > 0 { compactTextWidth = w }
            }
    }

    @ViewBuilder private var addButton: some View {
        if let onAdd {
            ComposerCircleButton("Add images", systemImage: "plus", size: buttonSize, action: onAdd)
                .disabled(isBusy)
        }
    }

    @ViewBuilder private var sendStopButton: some View {
        if isBusy {
            ComposerCircleButton(
                "Stop", systemImage: "stop.fill", size: buttonSize, prominent: true, action: onStop)
        } else {
            ComposerCircleButton(
                "Send", systemImage: "arrow.up", size: buttonSize, prominent: true, action: onSend)
                .disabled(!canSend)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            addButton
            Spacer(minLength: 0)
            sendStopButton
        }
    }
}

/// A round icon button of the composer's action row, `size` points wide and high. `prominent` fills it
/// with the accent color (send, stop).
private struct ComposerCircleButton: View {
    let title: String
    let systemImage: String
    let size: CGFloat
    let prominent: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String, size: CGFloat, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(prominent ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}

/// An image waiting in the composer, with a round button in its corner that removes it.
private struct PendingImageThumbnail: View {
    let data: Data
    let onRemove: () -> Void

    var body: some View {
        (ImageAttachmentLoader.thumbnail(for: data) ?? Image(systemName: "photo"))
            .resizable()
            .scaledToFill()
            .frame(width: 80, height: 80)
            .clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(.white, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove image")
                .padding(5)
            }
    }
}

/// A short status line (progress, error, notice) floating above the composer, readable over the
/// messages that scroll beneath it.
struct ComposerStatus<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 6) {
            content
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 12)
    }
}
