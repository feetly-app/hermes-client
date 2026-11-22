import Foundation

/// The lines the instance writes into a stored user message for each image sent with it.
///
/// The instance keeps the text of a message, not its image parts. Each image becomes a line
/// `[Image attached at: <server path>]` (or `[Image attached: <url>]` for a remote image), and the session
/// store adds one `[screenshot]` placeholder line per image at the end. The server path is
/// `.../native-inputs/<sha256 of the bytes>/<name>`, so the digest identifies the image.
public enum StoredImageMarkers {
    /// One image named by a stored message.
    public struct Reference: Equatable, Sendable {
        /// The server path or URL, as written in the message.
        public let location: String
        /// The SHA-256 of the image bytes, lowercase hex, when the path carries it.
        public let sha256: String?
    }

    private static let pathPrefix = "[Image attached at: "
    private static let urlPrefix = "[Image attached: "
    private static let placeholder = "[screenshot]"

    /// Splits a stored message into its text, trimmed, and the images it names. Marker lines are removed,
    /// and so are the trailing `[screenshot]` placeholders when the message names at least one image.
    public static func parse(_ content: String) -> (text: String, images: [Reference]) {
        var images: [Reference] = []
        var kept: [Substring] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if let reference = reference(in: line.trimmingCharacters(in: .whitespaces)) {
                images.append(reference)
            } else {
                kept.append(line)
            }
        }
        if !images.isEmpty {
            while let last = kept.last,
                  last.trimmingCharacters(in: .whitespaces) == placeholder
                    || last.trimmingCharacters(in: .whitespaces).isEmpty
            {
                kept.removeLast()
            }
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, images)
    }

    private static func reference(in line: String) -> Reference? {
        guard line.hasSuffix("]") else { return nil }
        for prefix in [pathPrefix, urlPrefix] where line.hasPrefix(prefix) {
            let location = String(line.dropFirst(prefix.count).dropLast())
            guard !location.isEmpty else { return nil }
            return Reference(location: location, sha256: digest(in: location))
        }
        return nil
    }

    /// The name of the folder holding the file, when it is a SHA-256 in hex.
    private static func digest(in path: String) -> String? {
        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }
        let folder = components[components.count - 2].lowercased()
        guard folder.count == 64, folder.allSatisfy(\.isHexDigit) else { return nil }
        return folder
    }
}
