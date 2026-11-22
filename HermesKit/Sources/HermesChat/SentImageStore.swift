import Foundation
import HermesAPI

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// The images sent from this device, kept by the SHA-256 of their bytes.
///
/// The instance does not send images back with a session's messages. It stores each one under a path named
/// after the SHA-256 of its bytes, and the message text only names that path (see `StoredImageMarkers`).
/// Keeping a copy of every image sent, under the same digest, lets the transcript show the image again.
public protocol SentImageStore: Sendable {
    /// Keeps a copy of `image`. Failures are ignored: the image then shows as not available.
    func save(_ image: ImageAttachment)
    /// The image whose bytes have this SHA-256 (lowercase hex), or `nil` if it was not sent from here.
    func image(sha256: String) -> ImageAttachment?
}

/// The lowercase hex SHA-256 of `data`.
public func sha256Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
        PortableSHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    #endif
}

/// Keeps the images in memory. For tests and previews.
public final class InMemorySentImageStore: SentImageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: ImageAttachment] = [:]

    public init() {}

    public func save(_ image: ImageAttachment) {
        let key = sha256Hex(image.data)
        lock.withLock { images[key] = image }
    }

    public func image(sha256: String) -> ImageAttachment? {
        lock.withLock { images[sha256.lowercased()] }
    }
}

/// Keeps the images as files in a directory, one per image, named `<sha256>.<extension>`.
public struct DirectorySentImageStore: SentImageStore {
    public let directory: URL

    private static let extensions: [(mimeType: String, ext: String)] = [
        ("image/jpeg", "jpg"), ("image/png", "png"), ("image/gif", "gif"), ("image/webp", "webp"),
        ("image/heic", "heic"),
    ]

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Sent Images` in the caches directory: the system may purge it, the images then show as not available.
    public static func inCaches() -> DirectorySentImageStore? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return DirectorySentImageStore(directory: caches.appendingPathComponent("Sent Images", isDirectory: true))
    }

    public func save(_ image: ImageAttachment) {
        let ext = Self.extensions.first { $0.mimeType == image.mimeType.lowercased() }?.ext ?? "img"
        let file = directory.appendingPathComponent("\(sha256Hex(image.data)).\(ext)")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? image.data.write(to: file, options: .atomic)
    }

    public func image(sha256: String) -> ImageAttachment? {
        let key = sha256.lowercased()
        guard key.count == 64, key.allSatisfy(\.isHexDigit) else { return nil }
        for (mimeType, ext) in Self.extensions + [("image/jpeg", "img")] {
            let file = directory.appendingPathComponent("\(key).\(ext)")
            if let data = try? Data(contentsOf: file) {
                return ImageAttachment(mimeType: mimeType, data: data)
            }
        }
        return nil
    }
}

#if !canImport(CryptoKit)
    /// SHA-256 for platforms without CryptoKit (the Linux toolchain that runs the tests).
    enum PortableSHA256 {
        private static let k: [UInt32] = [
            0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
            0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
            0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
            0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
            0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
            0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
            0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
            0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
        ]

        static func hash(_ data: Data) -> [UInt8] {
            var h: [UInt32] = [
                0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
            ]
            var message = [UInt8](data)
            let bitLength = UInt64(message.count) * 8
            message.append(0x80)
            while message.count % 64 != 56 { message.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

            var w = [UInt32](repeating: 0, count: 64)
            for chunk in stride(from: 0, to: message.count, by: 64) {
                for i in 0..<16 {
                    let j = chunk + i * 4
                    w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8
                        | UInt32(message[j + 3])
                }
                for i in 16..<64 {
                    let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                    let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                    w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                }
                var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
                for i in 0..<64 {
                    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = s0 &+ maj
                    (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
                }
                h[0] = h[0] &+ a
                h[1] = h[1] &+ b
                h[2] = h[2] &+ c
                h[3] = h[3] &+ d
                h[4] = h[4] &+ e
                h[5] = h[5] &+ f
                h[6] = h[6] &+ g
                h[7] = h[7] &+ hh
            }
            return h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - $0 * 8)) } }
        }

        private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
            (x >> n) | (x << (32 - n))
        }
    }
#endif
