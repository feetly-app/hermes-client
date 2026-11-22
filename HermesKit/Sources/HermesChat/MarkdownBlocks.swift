/// A block of a message. Inline Markdown (emphasis, code spans, links) is left in the text and rendered later.
public enum MarkdownBlock: Equatable, Sendable {
    /// A paragraph. Its single line breaks are kept.
    case text(String)
    case code(language: String?, code: String)
    /// `# Title` to `###### Title`.
    case heading(level: Int, text: String)
    /// Consecutive list items, bulleted or numbered, possibly nested.
    case list([MarkdownListItem])
    /// `> quoted text`, its lines joined.
    case quote(String)
    /// A `---`, `***` or `___` line.
    case rule
    /// A pipe table: a header row, a delimiter row, then body rows. Rows are padded to the header width.
    case table(header: [String], alignments: [MarkdownAlignment], rows: [[String]])
}

/// One list item: its marker as written (`1.`, `2)`) or `nil` for a bullet, its text, and how deep it is
/// nested (0 for the outer list).
public struct MarkdownListItem: Equatable, Sendable {
    public let number: String?
    public let text: String
    public let level: Int

    public init(number: String?, text: String, level: Int) {
        self.number = number
        self.text = text
        self.level = level
    }
}

/// Alignment of a table column, from the colons of the delimiter row.
public enum MarkdownAlignment: Equatable, Sendable {
    case leading, center, trailing
}

/// Splits a message into blocks: paragraphs, fenced code, headings, lists, quotes, rules and tables.
///
/// The common subset the models write, read line by line. A fence opens with three or more backticks or
/// tildes and closes with the same marker alone on a line; an unclosed fence runs to the end of the text, so
/// a reply that is still streaming shows its code block. A table needs its delimiter row (`|---|---|`).
/// Anything else is prose.
public enum MarkdownParser {
    public static func blocks(in source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var items: [MarkdownListItem] = []
        var quote: [String] = []
        var lines = source.components(separatedBy: "\n")[...]

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingBlankLines()
            if !text.isEmpty {
                blocks.append(.text(text))
            }
            prose.removeAll()
        }
        func flushList() {
            if !items.isEmpty {
                blocks.append(.list(items))
            }
            items.removeAll()
        }
        func flushQuote() {
            let text = quote.joined(separator: "\n").trimmingBlankLines()
            if !text.isEmpty {
                blocks.append(.quote(text))
            }
            quote.removeAll()
        }
        func flushAll() {
            flushProse()
            flushList()
            flushQuote()
        }

        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = openingFence(line) {
                flushAll()
                var code: [String] = []
                while let inner = lines.popFirst() {
                    if isClosingFence(inner, marker: fence.marker, length: fence.length) {
                        break
                    }
                    code.append(inner)
                }
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                // A blank line ends a paragraph and a quote. A list goes on if the next item follows.
                flushProse()
                flushQuote()
                if !items.isEmpty, let next = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                   listItem(next) != nil
                {
                    continue
                }
                flushList()
                continue
            }

            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushProse()
                flushList()
                var text = trimmed.dropFirst()
                if text.first == " " {
                    text = text.dropFirst()
                }
                quote.append(String(text))
                continue
            }

            if trimmed.hasPrefix("|"), let next = lines.first, let alignments = delimiterRow(next) {
                flushAll()
                lines.removeFirst()
                let header = cells(of: trimmed)
                var rows: [[String]] = []
                while let row = lines.first, row.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    lines.removeFirst()
                    rows.append(padded(cells(of: row.trimmingCharacters(in: .whitespaces)), to: header.count))
                }
                blocks.append(.table(header: header, alignments: padded(alignments, to: header.count), rows: rows))
                continue
            }

            if let item = listItem(line) {
                flushProse()
                flushQuote()
                items.append(item)
                continue
            }

            // A line under a list item, indented, continues it; any other line ends the list.
            if let last = items.last, line.first == " " || line.first == "\t" {
                items[items.count - 1] = MarkdownListItem(
                    number: last.number, text: last.text + "\n" + trimmed, level: last.level
                )
                continue
            }
            flushList()
            flushQuote()
            prose.append(line)
        }
        flushAll()
        return blocks
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?
    }

    private static func openingFence(_ line: String) -> Fence? {
        let trimmed = line.trimmingLeadingSpaces()
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") {
            return nil
        }
        return Fence(marker: marker, length: length, language: info.isEmpty ? nil : info)
    }

    private static func isClosingFence(_ line: String, marker: Character, length: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == marker }
    }

    /// Three or more `-`, `*` or `_`, the same character, spaces allowed between them.
    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard let first = marks.first, "-*_".contains(first), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        // Closing hashes, as in `## Title ##`, are not part of the title.
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            text.removeLast()
        }
        return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }

    /// `- item`, `* item`, `+ item`, `1. item` or `1) item`. Two spaces (or a tab) of indentation make a
    /// nesting level.
    private static func listItem(_ line: String) -> MarkdownListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.dropFirst(indent.count)
        guard let first = body.first else { return nil }
        let marker: Substring
        if "-*+".contains(first) {
            marker = body.prefix(1)
        } else {
            let digits = body.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = body.dropFirst(digits.count)
            guard let punctuation = after.first, punctuation == "." || punctuation == ")" else { return nil }
            marker = body.prefix(digits.count + 1)
        }
        let rest = body.dropFirst(marker.count)
        guard let space = rest.first, space == " " || space == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownListItem(
            number: "-*+".contains(first) ? nil : String(marker),
            text: text,
            level: min(width / 2, 4)
        )
    }

    /// The alignments of a `|---|:---:|---:|` row, or `nil` if the line is not one.
    private static func delimiterRow(_ line: String) -> [MarkdownAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return nil }
        var alignments: [MarkdownAlignment] = []
        for cell in cells(of: trimmed) {
            guard !cell.isEmpty, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-") else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// The cells of a table row, trimmed. The outer pipes are optional and `\|` is a literal pipe.
    private static func cells(of row: String) -> [String] {
        var text = Substring(row)
        if text.hasPrefix("|") {
            text = text.dropFirst()
        }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") {
            text = text.dropLast()
        }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func padded<T>(_ values: [T], to count: Int) -> [T] where T: DefaultValue {
        values.count >= count ? Array(values.prefix(count)) : values + Array(repeating: T.defaultValue, count: count - values.count)
    }
}

private protocol DefaultValue {
    static var defaultValue: Self { get }
}

extension String: DefaultValue {
    fileprivate static var defaultValue: String { "" }
}

extension MarkdownAlignment: DefaultValue {
    fileprivate static var defaultValue: MarkdownAlignment { .leading }
}

extension String {
    fileprivate func trimmingLeadingSpaces() -> String {
        String(drop(while: { $0 == " " || $0 == "\t" }))
    }

    /// Removes leading and trailing blank lines, keeps the inner ones.
    fileprivate func trimmingBlankLines() -> String {
        var lines = components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
