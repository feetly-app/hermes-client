import HermesAPI
import SwiftUI

/// The images of a message, shown above its text. A single image is shown large, at its own aspect ratio;
/// several sit side by side as squares. A tap opens an image full size. Images this device has no copy of
/// (sent from elsewhere) show as placeholder tiles.
struct MessageImages: View {
    let images: [ImageAttachment]
    var missingCount = 0
    /// `.trailing` for a message from the user.
    var alignment: HorizontalAlignment = .leading

    @State private var opened: OpenedImage?

    private static let singleSize: CGFloat = 240
    private static let tileSize: CGFloat = 120

    var body: some View {
        Group {
            if images.count == 1, missingCount == 0 {
                button(for: 0) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: Self.singleSize, maxHeight: Self.singleSize)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(images.indices, id: \.self) { index in
                            button(for: index) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: Self.tileSize, height: Self.tileSize)
                            }
                        }
                        ForEach(0..<missingCount, id: \.self) { _ in
                            MissingImageTile(size: Self.tileSize)
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

    private func button<Content: View>(for index: Int, @ViewBuilder content: (Image) -> Content) -> some View {
        let data = images[index].data
        return Button {
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

private struct OpenedImage: Identifiable {
    let id = UUID()
    let data: Data
}

/// Stands in for an image the instance holds but this device has no copy of.
private struct MissingImageTile: View {
    let size: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.title2)
            Text("Not on this device")
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(width: size, height: size)
        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image not available on this device")
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
