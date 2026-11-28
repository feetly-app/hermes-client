import HermesAPI
import HermesChat
import SwiftUI

/// The message composer floating over the bottom of a conversation: a rounded glass card with the
/// images waiting to be sent, the text field, and the action buttons (add, send).
///
/// Layout mirrors ChatGPT: single-row when the draft fits on one line, then animates to a stacked
/// layout (text full-width on top, button row below) as the user types.
///
/// **Keyboard preservation**: a custom `ComposerInputLayout` holds the add button, the text field,
/// and the send button as three always-present subviews. The layout repositions them between
/// compact and expanded without ever removing or re-adding any view, so SwiftUI never drops focus
/// and the keyboard stays up during the transition.
///
/// **Button stability**: in both modes the buttons are placed at `bounds.maxY - buttonSize`.
/// Because the card is anchored to the bottom of the screen, `bounds.maxY` is a fixed screen
/// coordinate — the buttons do not move as the card grows upward.
///
/// **Expansion detection**: a hidden measurement TextField constrained to the compact text-field
/// width (captured at runtime) drives `isExpanded` via its height, with no hardcoded character
/// count and no feedback loop.
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
    let canSend: Bool
    let onSend: () -> Void

    @State private var isExpanded = false
    @State private var viewedImage: ViewedImage?
    @Namespace private var imageNamespace
    @State private var singleLineHeight: CGFloat = 0
    @State private var compactTextWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .subheadline) private var buttonSize: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !pendingImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, image in
                            PendingImageThumbnail(data: image.data) {
                                viewedImage = ViewedImage(id: "pending-\(index)", data: image.data)
                            } onRemove: {
                                onRemoveImage(index)
                            }
                            .imageViewerSource(
                                id: "pending-\(index)", in: imageNamespace,
                                cornerRadius: PendingImageThumbnail.cornerRadius
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .imageViewer($viewedImage, in: imageNamespace)
            }

            ComposerInputLayout(isExpanded: isExpanded, buttonSize: buttonSize, spacing: 8) {
                if let onAdd {
                    ComposerCircleButton(
                        "Add images", systemImage: "plus", size: buttonSize, action: onAdd)
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
                composerTextField
                ComposerCircleButton(
                    "Send", systemImage: "arrow.up", size: buttonSize,
                    prominent: true, action: onSend)
                    .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(alignment: .top) { measurementProbe }
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.28, bounce: 0.12), value: isExpanded)
    }

    private var measurementProbe: some View {
        TextField("", text: $draft, axis: .vertical)
            .lineLimit(1 ... 6)
            .textFieldStyle(.plain)
            .padding(.vertical, 7)
            .frame(width: compactTextWidth > 0 ? compactTextWidth : nil, alignment: .leading)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                if singleLineHeight == 0 { singleLineHeight = h }
                guard singleLineHeight > 0 else { return }
                isExpanded = h > singleLineHeight + 2
            }
    }

    @ViewBuilder private var composerTextField: some View {
        TextField("Message", text: $draft, axis: .vertical)
            .focused(isFocused)
            .textFieldStyle(.plain)
            .lineLimit(1 ... 6)
            .padding(.vertical, 7)
            .sendsOnReturn(isActive: isFocused.wrappedValue, canSend: canSend, action: onSend)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in
                if !isExpanded, w > 0 { compactTextWidth = w }
            }
    }
}

private struct ComposerInputLayout: Layout {
    var isExpanded: Bool
    var buttonSize: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return proposal.replacingUnspecifiedDimensions() }
        let totalWidth = proposal.replacingUnspecifiedDimensions().width
        let hasLeading = subviews[0].sizeThatFits(.unspecified).width > 0
        if isExpanded {
            let textH = subviews[1].sizeThatFits(ProposedViewSize(width: totalWidth, height: nil)).height
            return CGSize(width: totalWidth, height: textH + spacing + buttonSize)
        } else {
            var textW = totalWidth - buttonSize - spacing
            if hasLeading { textW -= buttonSize + spacing }
            let textH = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, textW), height: nil)).height
            return CGSize(width: totalWidth, height: max(textH, buttonSize))
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let hasLeading = subviews[0].sizeThatFits(.unspecified).width > 0
        let buttonY = bounds.maxY - buttonSize
        let bp = ProposedViewSize(width: buttonSize, height: buttonSize)
        if isExpanded {
            let textH = bounds.height - spacing - buttonSize
            subviews[1].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: textH))
            if hasLeading {
                subviews[0].place(at: CGPoint(x: bounds.minX, y: buttonY), anchor: .topLeading, proposal: bp)
            }
            subviews[2].place(at: CGPoint(x: bounds.maxX - buttonSize, y: buttonY), anchor: .topLeading, proposal: bp)
        } else {
            var leadingEdge = bounds.minX
            if hasLeading {
                subviews[0].place(at: CGPoint(x: leadingEdge, y: buttonY), anchor: .topLeading, proposal: bp)
                leadingEdge += buttonSize + spacing
            }
            subviews[2].place(at: CGPoint(x: bounds.maxX - buttonSize, y: buttonY), anchor: .topLeading, proposal: bp)
            let textW = bounds.maxX - buttonSize - spacing - leadingEdge
            subviews[1].place(at: CGPoint(x: leadingEdge, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: max(0, textW), height: nil))
        }
    }
}

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

/// An image waiting to be sent. A tap opens it full size; the cross removes it.
private struct PendingImageThumbnail: View {
    let data: Data
    let onOpen: () -> Void
    let onRemove: () -> Void

    static let cornerRadius: CGFloat = 14

    var body: some View {
        Button(action: onOpen) {
            (ImageAttachmentLoader.thumbnail(for: data) ?? Image(systemName: "photo"))
                .resizable()
                .scaledToFill()
                .frame(width: 80, height: 80)
                .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
                .contentShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image")
        .accessibilityHint("Opens the image full size")
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
