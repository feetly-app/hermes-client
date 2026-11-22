import HermesAPI
import HermesChat
import SwiftUI

/// The images of a message, shown above its text. A single image is shown large, at its own aspect ratio;
/// several sit side by side as squares. A tap opens an image full size. Images a stored message names are
/// loaded through the sidecar; without one, or when the image is gone, they show as placeholder tiles.
struct MessageImages: View {
    let images: [MessageImage]
    /// Loads the images stored messages name, `nil` without a sidecar.
    var loader: StoredImageLoader?
    /// `.trailing` for a message from the user.
    var alignment: HorizontalAlignment = .leading

    @State private var opened: OpenedImage?

    private static let singleSize: CGFloat = 240
    private static let tileSize: CGFloat = 120

    var body: some View {
        Group {
            if images.count == 1 {
                MessageImageTile(
                    image: images[0], loader: loader, placeholderSize: Self.tileSize, opened: $opened
                ) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: Self.singleSize, maxHeight: Self.singleSize)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(images.indices, id: \.self) { index in
                            MessageImageTile(
                                image: images[index], loader: loader, placeholderSize: Self.tileSize, opened: $opened
                            ) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: Self.tileSize, height: Self.tileSize)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // Also aligns images that fit: on the right for a message from the user.
                .defaultScrollAnchor(alignment == .trailing ? .trailing : .leading)
            }
        }
        .sheet(item: $opened) { opened in
            ImageViewer(data: opened.data)
        }
    }
}

private struct OpenedImage: Identifiable {
    let id = UUID()
    let data: Data
}

/// One image of a message: its bytes when at hand, else loaded from the sidecar by digest.
private struct MessageImageTile<Content: View>: View {
    let image: MessageImage
    let loader: StoredImageLoader?
    let placeholderSize: CGFloat
    @Binding var opened: OpenedImage?
    @ViewBuilder let content: (Image) -> Content

    @State private var loaded: Data?
    @State private var isUnavailable = false

    var body: some View {
        switch image {
        case .attached(let attachment):
            button(for: attachment.data)
        case .stored(let sha256):
            if let loaded {
                button(for: loaded)
            } else if let sha256, let loader, !isUnavailable {
                LoadingImageTile(size: placeholderSize)
                    .task(id: sha256) {
                        let image = await loader.image(sha256: sha256)
                        guard !Task.isCancelled else { return }
                        if let image {
                            loaded = image.data
                        } else {
                            isUnavailable = true
                        }
                    }
            } else {
                UnavailableImageTile(size: placeholderSize)
            }
        }
    }

    private func button(for data: Data) -> some View {
        Button {
            opened = OpenedImage(data: data)
        } label: {
            content(ImageAttachmentLoader.thumbnail(for: data, maxPixelSize: 720) ?? Image(systemName: "photo"))
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image")
        .accessibilityHint("Opens the image full size")
    }
}

/// Stands in for a stored image while the sidecar sends it.
private struct LoadingImageTile: View {
    let size: CGFloat

    var body: some View {
        ProgressView()
            .frame(width: size, height: size)
            .background(.primary.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
            .accessibilityLabel("Loading image")
    }
}

/// Stands in for an image the instance holds but the app cannot get: no sidecar is configured, or the
/// image is gone.
private struct UnavailableImageTile: View {
    let size: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.title2)
            Text("Not available")
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(width: size, height: size)
        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image not available")
    }
}

/// One image, full size, fitted to the screen.
private struct ImageViewer: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image = ImageAttachmentLoader.thumbnail(for: data, maxPixelSize: 4096) {
                    image
                        .resizable()
                        .scaledToFit()
                } else {
                    ContentUnavailableView("Unreadable image", systemImage: "photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}
