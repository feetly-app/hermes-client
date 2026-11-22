import Foundation
import Testing

@testable import HermesChat

@Suite("Long message text")
struct LongTextTests {
    @Test("a text up to the threshold, such as a long reply, is shown whole")
    func shortText() {
        #expect(LongText.preview(of: "Hello") == nil)
        #expect(LongText.preview(of: String(repeating: "word ", count: 2400)) == nil)
        #expect(LongText.preview(of: String(repeating: "a", count: 10), threshold: 10, limit: 5) == nil)
    }

    @Test("a long text is cut at a line end, else a word end, else at the limit")
    func previewCuts() {
        #expect(LongText.preview(of: "first line\nsecond line goes on", threshold: 15, limit: 15) == "first line")
        #expect(LongText.preview(of: "one two three four five", threshold: 12, limit: 12) == "one two")
        #expect(LongText.preview(of: String(repeating: "x", count: 30), threshold: 12, limit: 12) == String(repeating: "x", count: 12))
    }

    @Test("a pasted JSON page of 345,000 characters on one line gives a short preview")
    func pastedJSON() throws {
        let row = #"{"id": 4730, "role": "user", "content": "Tu as accès aux repos", "display_kind": null}, "#
        let text = #"{"object": "list", "data": ["# + String(repeating: row, count: 4000) + "]}"
        #expect(text.count > 345_000)

        let preview = try #require(LongText.preview(of: text))
        #expect(preview.count <= LongText.previewLimit)
        #expect(preview.count > LongText.previewLimit / 2)
        #expect(text.hasPrefix(preview))
    }

    @Test("chunks give the whole text back, each piece at most the chunk size")
    func chunks() {
        let text = (0..<500).map { "line \($0) with some words" }.joined(separator: "\n")
            + String(repeating: "z", count: 5000)
        let pieces = LongText.chunks(of: text, size: 300)

        #expect(pieces.joined() == text)
        #expect(pieces.allSatisfy { $0.count <= 300 })
        #expect(pieces.count > 1)
        #expect(LongText.chunks(of: "") == [""])
        #expect(LongText.chunks(of: "short") == ["short"])
    }
}
