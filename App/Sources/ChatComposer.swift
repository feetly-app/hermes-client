import HermesAPI
import HermesChat
import SwiftUI

/// The message composer floating over the bottom of a conversation: a rounded glass card with the
/// images waiting to be sent, the text field, and the action buttons (add, send or stop) aligned
/// to the bottom of the text field so the card stays compact when empty and grows only as needed.
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

    /// Diameter of the round action buttons. Matches the previous action-row height so the
    /// overall card stays the same size on a single-line input as before.
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

            HStack(alignment: .bottom, spacing: 8) {
                if let onAdd {
                    ComposerCircleButton("Add images", systemImage: "plus", size: buttonSize, action: onAdd)
                        .disabled(isBusy)
                }

                TextField("Message", text: $draft, axis: .vertical)
                    .focused(isFocused)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 6)
                    .padding(.vertical, 7)

                if isBusy {
                    ComposerCircleButton(
                        "Stop", systemImage: "stop.fill", size: buttonSize, prominent: true, action: onStop)
                } else {
                    ComposerCircleButton(
                        "Send", systemImage: "arrow.up", size: buttonSize, prominent: true, action: onSend)
                        .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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
