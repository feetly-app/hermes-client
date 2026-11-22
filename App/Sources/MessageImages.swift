import HermesAPI
import HermesChat
import SwiftUI

/// The images of a message, shown above its text and aligned with it: on the right edge of the bubble
/// for a message from the user.
///
/// A single image is drawn at its own aspect ratio, within `ImageLayout.single`; several sit side by side
/// as squares. Every image has rounded corners and a hairline edge, so it holds on any background. A tap
/// opens it full size (with a zoom from the thumbnail on iOS). Images a stored message names are loaded
/// through the sidecar; without one, or when the image is gone, they show as a placeholder.
struct MessageImages: View {
    let images: [MessageImage]
    /// Loads the images stored messages name, `nil` without a sidecar.
    var loader: StoredImageLoader?
    /// `.trailing` for a message from the user.
    var alignment: HorizontalAlignment = .leading

    @State private var opened: OpenedImage?
    @Namespace private var namespace

    var body: some View {
        Group {
            if images.count == 1 {
                tile(at: 0, style: .single)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(images.indices, id: \.self) { index in
                            tile(at: index, style: .square)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                // Also aligns images that fit: on the right for a message from the user.
                .defaultScrollAnchor(alignment == .trailing ? .trailing : .leading)
            }
        }
        #if os(iOS)
            .fullScreenCover(item: $opened) { opened in
                ImageViewer(data: opened.data)
                    .navigationTransition(.zoom(sourceID: opened.index, in: namespace))
            }
        #else
            .sheet(item: $opened) { opened in
                ImageViewer(data: opened.data)
            }
        #endif
    }

    private func tile(at index: Int, style: ImageLayout.Style) -> some View {
        MessageImageTile(image: images[index], loader: loader, style: style) { data in
            opened = OpenedImage(index: index, data: data)
        }
        #if os(iOS)
            .matchedTransitionSource(id: index, in: namespace) { source in
                source.clipShape(.rect(cornerRadius: style.cornerRadius, style: .continuous))
            }
        #endif
    }
}

private struct OpenedImage: Identifiable {
    let index: Int
    let data: Data

    var id: Int { index }
}

/// Sizes and corner radii of message images.
enum ImageLayout {
    enum Style {
        /// The only image of a message, at its own aspect ratio.
        case single
        /// One of several images, as a square.
        case square

        var cornerRadius: CGFloat {
            switch self {
            case .single: 20
            case .square: 14
            }
        }

        /// The size of the placeholder shown while the image loads or when it is not available.
        var placeholderSize: CGSize {
            switch self {
            case .single: CGSize(width: 200, height: 200)
            case .square: CGSize(width: squareSide, height: squareSide)
            }
        }
    }

    static let maxWidth: CGFloat = 260
    static let maxHeight: CGFloat = 240
    /// Shortest side of a single image: a panorama or a long screenshot is cropped rather than drawn as a
    /// thin strip.
    static let minSide: CGFloat = 96
    static let squareSide: CGFloat = 116

    /// The size a single image is drawn at: as large as fits in `maxWidth` × `maxHeight` at its aspect
    /// ratio (`width / height`), with no side under `minSide`.
    static func singleSize(aspectRatio: CGFloat) -> CGSize {
        let ratio = aspectRatio > 0 ? aspectRatio : 1
        var width = min(maxWidth, maxHeight * ratio)
        var height = width / ratio
        if height < minSide {
            height = minSide
        }
        if width < minSide {
            width = minSide
            height = min(maxHeight, width / ratio)
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}

/// One image of a message: its bytes when at hand, else loaded from the sidecar by digest.
private struct MessageImageTile: View {
    let image: MessageImage
    let loader: StoredImageLoader?
    let style: ImageLayout.Style
    let onOpen: (Data) -> Void

    @State private var data: Data?
    @State private var preview: ImagePreview?
    @State private var isUnavailable = false

    var body: some View {
        Group {
            if let preview, let data {
                Button {
                    onOpen(data)
                } label: {
                    picture(preview)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Image")
                .accessibilityHint("Opens the image full size")
            } else if isUnavailable {
                UnavailableImage(style: style)
            } else {
                LoadingImage(style: style)
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: preview != nil)
        // An image sent from here is decoded before the first frame, so it never flashes a placeholder.
        .onAppear {
            if case .attached(let attachment) = image, preview == nil {
                show(attachment.data)
            }
        }
        .task(id: image) {
            guard case .stored(let sha256) = image, preview == nil else { return }
            guard let sha256, let loader else {
                isUnavailable = true
                return
            }
            let loaded = await loader.image(sha256: sha256)
            guard !Task.isCancelled else { return }
            if let loaded {
                show(loaded.data)
            } else {
                isUnavailable = true
            }
        }
    }

    private func show(_ bytes: Data) {
        guard let decoded = ImageAttachmentLoader.preview(for: bytes, maxPixelSize: 900) else {
            isUnavailable = true
            return
        }
        data = bytes
        preview = decoded
    }

    private func picture(_ preview: ImagePreview) -> some View {
        let size = switch style {
        case .single: ImageLayout.singleSize(aspectRatio: preview.aspectRatio)
        case .square: CGSize(width: ImageLayout.squareSide, height: ImageLayout.squareSide)
        }
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        return preview.image
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            .contentShape(shape)
    }
}

/// Stands in for a stored image while the sidecar sends it.
private struct LoadingImage: View {
    let style: ImageLayout.Style

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: style.placeholderSize.width, height: style.placeholderSize.height)
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: style.cornerRadius, style: .continuous))
            .accessibilityLabel("Loading image")
    }
}

/// Stands in for an image the instance holds but the app cannot get: no sidecar is configured, or the
/// image is gone.
private struct UnavailableImage: View {
    let style: ImageLayout.Style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.title3)
            Text("Not available")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(width: ImageLayout.squareSide, height: ImageLayout.squareSide)
        .background(.primary.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image not available")
    }
}

/// One image, full size, on black. Pinch or double-tap to zoom, drag to look around a zoomed image.
/// On iOS, a swipe down closes it back into its thumbnail.
private struct ImageViewer: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @State private var preview: ImagePreview?

    private static let maxZoom: CGFloat = 4

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let preview {
                preview.image
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom * pinch)
                    .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                    .gesture(magnify)
                    .gesture(pan, including: zoom > 1 ? .all : .subviews)
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            zoom = zoom > 1 ? 1 : 2.5
                            offset = .zero
                        }
                    }
                    .accessibilityLabel("Image")
                    .accessibilityAddTraits(.isImage)
            } else {
                ContentUnavailableView("Unreadable image", systemImage: "photo")
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .top) { toolbar }
        .onAppear {
            preview = ImageAttachmentLoader.preview(for: data, maxPixelSize: 4096)
        }
        #if os(macOS)
            .frame(minWidth: 560, minHeight: 420)
        #endif
    }

    private var toolbar: some View {
        HStack {
            if let preview {
                ShareLink(item: preview.image, preview: SharePreview("Image", image: preview.image)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .frame(width: 22, height: 22)
                }
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
            }
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                withAnimation(.snappy) {
                    zoom = min(max(zoom * value.magnification, 1), Self.maxZoom)
                    if zoom == 1 {
                        offset = .zero
                    }
                }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }
}
