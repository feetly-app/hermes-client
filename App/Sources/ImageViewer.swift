import SwiftUI

/// An image opened full size, from a message or from the composer.
struct ViewedImage: Identifiable {
    /// Matches the `imageViewerSource(id:in:cornerRadius:)` of the thumbnail it opens from.
    let id: String
    let data: Data
}

extension View {
    /// Presents `image` full size while it is set: on iOS a full-screen cover that zooms out of the
    /// thumbnail marked with the same id in `namespace`, on macOS a sheet.
    func imageViewer(_ image: Binding<ViewedImage?>, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
            fullScreenCover(item: image) { image in
                ImageViewer(data: image.data)
                    .navigationTransition(.zoom(sourceID: image.id, in: namespace))
            }
        #else
            sheet(item: image) { image in
                ImageViewer(data: image.data)
            }
        #endif
    }

    /// Marks a thumbnail as the place `imageViewer(_:in:)` zooms out of, and back into when it closes.
    func imageViewerSource(id: String, in namespace: Namespace.ID, cornerRadius: CGFloat) -> some View {
        #if os(iOS)
            matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            }
        #else
            self
        #endif
    }
}

/// One image, full size, edge to edge on black.
///
/// A tap shows or hides the close and share buttons. Pinch or double-tap to zoom; a zoomed image can be
/// dragged around, never past its edges. On iOS a swipe down on an image that is not zoomed closes it
/// back into its thumbnail.
struct ImageViewer: View {
    let data: Data

    @Environment(\.dismiss) private var dismiss
    @State private var preview: ImagePreview?
    @State private var showsChrome = true
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private static let maxZoom: CGFloat = 4
    private static let doubleTapZoom: CGFloat = 2.5

    init(data: Data) {
        self.data = data
        // Decoded up front so the zoom transition lands on the image, not on an empty screen.
        _preview = State(initialValue: ImageAttachmentLoader.preview(for: data, maxPixelSize: 4096))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let preview {
                    image(preview, in: proxy.size)
                } else {
                    ContentUnavailableView("Unreadable image", systemImage: "photo")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            chrome
                .opacity(showsChrome ? 1 : 0)
                .allowsHitTesting(showsChrome)
        }
        .animation(.easeInOut(duration: 0.2), value: showsChrome)
        .preferredColorScheme(.dark)
        #if os(iOS)
            .statusBarHidden(!showsChrome)
            .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        #else
            .frame(minWidth: 640, minHeight: 480)
        #endif
    }

    private func image(_ preview: ImagePreview, in container: CGSize) -> some View {
        let fitted = Self.fittedSize(aspectRatio: preview.aspectRatio, in: container)
        let scale = zoom * pinch
        let shown = Self.clamped(
            CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
            fitted: fitted, zoom: scale, container: container
        )
        return preview.image
            .resizable()
            .frame(width: fitted.width, height: fitted.height)
            .scaleEffect(scale)
            .offset(shown)
            .contentShape(.rect)
            .gesture(magnify(fitted: fitted, container: container))
            .gesture(pan(fitted: fitted, container: container), including: zoom > 1 ? .all : .subviews)
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    zoom = zoom > 1 ? 1 : Self.doubleTapZoom
                    offset = .zero
                }
            }
            .onTapGesture {
                showsChrome.toggle()
            }
            .accessibilityLabel("Image")
            .accessibilityAddTraits(.isImage)
    }

    private var chrome: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
                    .frame(width: 22, height: 22)
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if let preview {
                ShareLink(item: preview.image, preview: SharePreview("Image", image: preview.image)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                    .frame(width: 22, height: 22)
                }
            }
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.semibold))
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func magnify(fitted: CGSize, container: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                withAnimation(.snappy) {
                    zoom = min(max(zoom * value.magnification, 1), Self.maxZoom)
                    offset = Self.clamped(offset, fitted: fitted, zoom: zoom, container: container)
                }
            }
    }

    private func pan(fitted: CGSize, container: CGSize) -> some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let moved = CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height
                )
                offset = Self.clamped(moved, fitted: fitted, zoom: zoom, container: container)
            }
    }

    /// The size of an image of this aspect ratio (`width / height`) fitted in `container`.
    static func fittedSize(aspectRatio: CGFloat, in container: CGSize) -> CGSize {
        guard container.width > 0, container.height > 0, aspectRatio > 0 else { return container }
        if container.width / container.height > aspectRatio {
            return CGSize(width: container.height * aspectRatio, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / aspectRatio)
    }

    /// `offset` limited so a zoomed image never leaves a gap at an edge it overflows.
    static func clamped(_ offset: CGSize, fitted: CGSize, zoom: CGFloat, container: CGSize) -> CGSize {
        let maxX = max(0, (fitted.width * zoom - container.width) / 2)
        let maxY = max(0, (fitted.height * zoom - container.height) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}
