import HermesAPI
import HermesChat
import SwiftUI

/// The message composer floating over the bottom of a conversation: a rounded glass card with the
/// images waiting to be sent, the text field, and the action buttons (add, send or stop).
///
/// Layout mirrors ChatGPT: single-row (HStack) when the draft fits on one line, then animates to a
/// stacked layout (text full-width on top, button row below) as the user types.
///
/// A hidden measurement TextField — always spanning the full card width, never sharing a row with
/// buttons — drives the transition. Its height is compared against the single-line baseline captured
/// on first appear, so the threshold automatically adapts to any screen width, font size or Dynamic
/// Type setting with no hardcoded character count and no feedback loop.
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

            if isExpanded {
                // Expanded: text takes the full card width, action buttons sit below.
                VStack(alignment: .leading, spacing: 8) {
                    composerTextField
                    actionRow
                }
                .transition(.identity)
            } else {
                // Compact: single row — add button · text field · send/stop button.
                HStack(alignment: .bottom, spacing: 8) {
                    addButton
                    composerTextField
                    sendStopButton
                }
                .transition(.identity)
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

    /// A hidden, non-interactive copy of the text field that always spans the full card width.
    ///
    /// `onAppear` captures its height while the draft is empty → that is the single-line baseline.
    /// `onChange` fires whenever the draft grows and the probe wraps to more lines. Because the
    /// probe width never changes (no buttons share its row), the comparison is stable and there is
    /// no feedback loop between layout mode and wrap detection.
    private var measurementProbe: some View {
        TextField("", text: $draft, axis: .vertical)
            .lineLimit(1 ... 6)
            .textFieldStyle(.plain)
            .padding(.vertical, 7)
            .hidden()
            .allowsHitTesting(false)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            // Draft is empty on first appear → geo.size.height is the single-line baseline.
                            if singleLineHeight == 0 {
                                singleLineHeight = geo.size.height
                            }
                        }
                        .onChange(of: geo.size.height) { _, newHeight in
                            guard singleLineHeight > 0 else { return }
                            // 2 pt buffer avoids triggering on sub-pixel rounding differences.
                            isExpanded = newHeight > singleLineHeight + 2
                        }
                }
            )
    }

    // MARK: - Sub-views

    @ViewBuilder private var composerTextField: some View {
        TextField("Message", text: $draft, axis: .vertical)
            .focused(isFocused)
            .textFieldStyle(.plain)
            .lineLimit(1 ... 6)
            .padding(.vertical, 7)
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
