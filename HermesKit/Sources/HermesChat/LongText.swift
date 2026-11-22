import Foundation

/// Cuts long message text into pieces a view can draw.
///
/// SwiftUI draws a `Text` as one block: past a few tens of thousands of characters it draws nothing and
/// still takes its full height, so a pasted log or JSON page shows as an endless empty bubble. A transcript
/// shows the start of such a message (`preview(of:)`); the full text is shown in pieces (`chunks(of:)`),
/// each drawn on its own.
public enum LongText {
    /// Longest text a transcript line shows whole. Long replies stay whole; only pasted logs and the like
    /// go past it.
    public static let threshold = 12_000
    /// Length of the start shown for a text past `threshold`.
    public static let previewLimit = 3000
    /// Size of the pieces the full text is drawn in.
    public static let chunkSize = 2000

    /// The start of `text`, about `limit` characters cut at a line or word end, or `nil` when the text is
    /// not longer than `threshold` and is shown whole.
    public static func preview(of text: String, threshold: Int = threshold, limit: Int = previewLimit) -> String? {
        guard text.count > threshold else { return nil }
        let head = text.prefix(limit)
        return String(head[..<cutIndex(in: head)]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` in pieces of at most `size` characters, cut at line ends when one is near, else at word ends.
    /// Joined back together, the pieces give `text`.
    public static func chunks(of text: String, size: Int = chunkSize) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > size {
            let head = rest.prefix(size)
            let cut = cutIndex(in: head)
            pieces.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty || pieces.isEmpty {
            pieces.append(String(rest))
        }
        return pieces
    }

    /// Where to cut `head`: after its last line break in its second half, else after its last space there,
    /// else at its end. Never at its start, so a cut always moves forward.
    private static func cutIndex(in head: Substring) -> Substring.Index {
        let half = head.index(head.startIndex, offsetBy: head.count / 2)
        let tail = head[half...]
        if let newline = tail.lastIndex(of: "\n") {
            return head.index(after: newline)
        }
        if let space = tail.lastIndex(where: { $0 == " " || $0 == "\t" }) {
            return head.index(after: space)
        }
        return head.endIndex
    }
}
