import HermesAPI
import HermesChat
import SwiftUI

/// The message composer floating over the bottom of a conversation: a rounded glass card with the
/// images waiting to be sent, the text field, and the action buttons (add, send or stop).
///
/// Layout mirrors ChatGPT: single-row (HStack) when the draft is short, then animates to a stacked
/// layout (text full-width on top, button row below) as the user types. The transition is a spring
/// animation driven by the text field's actual rendered height, not a hardcoded character count.
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

    /// Single-line text field height captured the first time the view is laid out.
    /// Used as the threshold for the expand trigger.
    @State private var singleLineHeight: CGFloat = 0

    /// Character count at which the compact text field last wrapped to a second line.
    /// Calibrated at runtime so the collapse threshold adapts to the actual font size
    /// and screen width — no hardcoded magic number needed.
    @State private var compactWrapCount: Int = 36

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
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        // Animate only when the layout mode flips; individual view changes (e.g. send ↔ stop)
        // are not animated at the container level.
        .animation(.spring(duration: 0.28, bounce: 0.12), value: isExpanded)
    }

    // MARK: - Sub-views

    /// The text field, with geometry observers that drive the layout transition.
    ///
    /// **Expand**: `onGeometryChange` observes the text field's actual rendered height while in
    /// compact mode (squeezed between buttons). When it grows past 130 % of the single-line
    /// baseline, the text has wrapped — we record the character count at that moment so the
    /// collapse threshold is calibrated to the real font size and screen width.
    ///
    /// **Collapse**: driven by character count at 75 % of the wrap count (hysteresis). We
    /// intentionally do NOT use the height for collapse: switching to expanded gives the text
    /// field more horizontal space, which can shrink its height back to one line — using that as
    /// a collapse signal would create a feedback loop between the two layout modes.
    @ViewBuilder private var composerTextField: some View {
        TextField("Message", text: $draft, axis: .vertical)
            .focused(isFocused)
            .textFieldStyle(.plain)
            .lineLimit(1 ... 6)
            .padding(.vertical, 7)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                // Track the minimum observed height as the single-line baseline, so the view
                // works correctly even when the draft is non-empty on first appear.
                if singleLineHeight == 0 || newHeight < singleLineHeight {
                    singleLineHeight = newHeight
                }
                guard !isExpanded, singleLineHeight > 0, newHeight > singleLineHeight * 1.3 else { return }
                if draft.count > 0 { compactWrapCount = draft.count }
                isExpanded = true
            }
            .onChange(of: draft) { _, new in
                // Collapse at 75 % of the wrap count. The factor provides enough hysteresis
                // that adding and removing one character at the boundary does not flicker.
                let collapseThreshold = Int(Double(compactWrapCount) * 0.75)
                if isExpanded, !new.contains("\n"), new.count < collapseThreshold {
                    isExpanded = false
                }
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
