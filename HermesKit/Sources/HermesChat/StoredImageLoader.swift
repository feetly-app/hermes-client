import Foundation
import HermesAPI

/// One image of a transcript line.
public enum MessageImage: Equatable, Sendable {
    /// An image whose bytes are at hand: one just sent from this device.
    case attached(ImageAttachment)
    /// An image the instance stored with a message, named by the SHA-256 of its bytes when its marker
    /// carries it (see `StoredImageMarkers`). `StoredImageLoader` gets it back through the sidecar.
    case stored(sha256: String?)
}

/// Gets back an image the instance stored, by the SHA-256 of its bytes. `nil` when it is not available.
public protocol StoredImageFetching: Sendable {
    func image(sha256: String) async throws -> ImageAttachment?
}

extension SidecarClient: StoredImageFetching {
    public func image(sha256: String) async throws -> ImageAttachment? {
        try await media(sha256: sha256)
    }
}

/// Loads the images stored messages name, through the optional hermes-sidecar (`GET /media/{sha256}`).
///
/// The instance keeps only a marker in the message text, so without a sidecar there is no loader and the
/// images show as not available. Images received are kept in `cache`: the bytes of a digest never change,
/// the sidecar checks them before sending. Concurrent requests for one digest share a single fetch.
public actor StoredImageLoader {
    private let fetcher: any StoredImageFetching
    private let cache: StoredImageCache?
    private var inFlight: [String: Task<ImageAttachment?, Never>] = [:]

    public init(fetcher: any StoredImageFetching, cache: StoredImageCache? = nil) {
        self.fetcher = fetcher
        self.cache = cache
    }

    /// The image with this SHA-256 (hex), from the cache or the sidecar. `nil` when the digest is invalid,
    /// the image is gone, or the request fails; a failure is not cached, so a later call tries again.
    public func image(sha256: String) async -> ImageAttachment? {
        let key = sha256.lowercased()
        guard StoredImageCache.isDigest(key) else { return nil }
        if let cached = cache?.image(sha256: key) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task { [fetcher, cache] () -> ImageAttachment? in
            guard let image = try? await fetcher.image(sha256: key) else { return nil }
            cache?.save(image, sha256: key)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }
}

/// The images received from the sidecar, as files in a directory named `<sha256>.<extension>`.
public struct StoredImageCache: Sendable {
    public let directory: URL

    private static let extensions: [(mimeType: String, ext: String)] = [
        ("image/jpeg", "jpg"), ("image/png", "png"), ("image/gif", "gif"), ("image/webp", "webp"),
    ]

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Message Images` in the caches directory: the system may purge it, the images are then fetched again.
    public static func inCaches() -> StoredImageCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return StoredImageCache(directory: caches.appendingPathComponent("Message Images", isDirectory: true))
    }

    static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }

    /// Keeps `image` under `sha256`. Failures are ignored: the image is fetched again next time.
    public func save(_ image: ImageAttachment, sha256: String) {
        let key = sha256.lowercased()
        guard Self.isDigest(key),
              let ext = Self.extensions.first(where: { $0.mimeType == image.mimeType.lowercased() })?.ext
        else { return }
        let file = directory.appendingPathComponent("\(key).\(ext)")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? image.data.write(to: file, options: .atomic)
    }

    /// The image kept under `sha256`, or `nil`.
    public func image(sha256: String) -> ImageAttachment? {
        let key = sha256.lowercased()
        guard Self.isDigest(key) else { return nil }
        for (mimeType, ext) in Self.extensions {
            let file = directory.appendingPathComponent("\(key).\(ext)")
            if let data = try? Data(contentsOf: file) {
                return ImageAttachment(mimeType: mimeType, data: data)
            }
        }
        return nil
    }
}
