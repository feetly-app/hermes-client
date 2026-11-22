import Testing

@testable import HermesChat

@Suite("Markdown blocks")
struct MarkdownParserTests {
    @Test("plain text is one text block")
    func plainText() {
        #expect(MarkdownParser.blocks(in: "Hello\nworld") == [.text("Hello\nworld")])
    }

    @Test("an empty source has no blocks")
    func empty() {
        #expect(MarkdownParser.blocks(in: "").isEmpty)
        #expect(MarkdownParser.blocks(in: "  \n\n ").isEmpty)
    }

    @Test("prose, a fenced block with its language, then prose")
    func fencedBlockBetweenProse() {
        let source = "Run this:\n```swift\nprint(1)\nprint(2)\n```\nThen stop."
        #expect(
            MarkdownParser.blocks(in: source) == [
                .text("Run this:"),
                .code(language: "swift", code: "print(1)\nprint(2)"),
                .text("Then stop."),
            ])
    }

    @Test("a fence without a language has no language")
    func fenceWithoutLanguage() {
        #expect(MarkdownParser.blocks(in: "```\nx\n```") == [.code(language: nil, code: "x")])
    }

    @Test("tilde fences are recognised and close only with a tilde fence")
    func tildeFence() {
        #expect(MarkdownParser.blocks(in: "~~~\n```\n~~~") == [.code(language: nil, code: "```")])
    }

    @Test("an unclosed fence (reply still streaming) runs to the end of the text")
    func unclosedFence() {
        #expect(
            MarkdownParser.blocks(in: "Here:\n```py\nprint(") == [
                .text("Here:"),
                .code(language: "py", code: "print("),
            ])
    }

    @Test("inline code with backticks on the same line is not a fence")
    func inlineCodeIsNotFence() {
        #expect(MarkdownParser.blocks(in: "Use `ls` or ``ls -la``.") == [.text("Use `ls` or ``ls -la``.")])
    }

    @Test("the code block keeps its indentation and blank lines")
    func codeKeepsWhitespace() {
        let source = "```\n    indented\n\n  more\n```"
        #expect(MarkdownParser.blocks(in: source) == [.code(language: nil, code: "    indented\n\n  more")])
    }

    @Test("headings from # to ######, closing hashes dropped; #hashtag is prose")
    func headings() {
        #expect(
            MarkdownParser.blocks(in: "# Title\n## Sub ##\n###### Six\n#hashtag") == [
                .heading(level: 1, text: "Title"),
                .heading(level: 2, text: "Sub"),
                .heading(level: 6, text: "Six"),
                .text("#hashtag"),
            ])
    }

    @Test("bulleted and numbered lists, nested by indentation, with continuation lines")
    func lists() {
        let source = "- one\n  - nested `code`\n    goes on\n* two\n\n1. first\n2) second"
        #expect(
            MarkdownParser.blocks(in: source) == [
                .list([
                    MarkdownListItem(number: nil, text: "one", level: 0),
                    MarkdownListItem(number: nil, text: "nested `code`\ngoes on", level: 1),
                    MarkdownListItem(number: nil, text: "two", level: 0),
                    MarkdownListItem(number: "1.", text: "first", level: 0),
                    MarkdownListItem(number: "2)", text: "second", level: 0),
                ])
            ])
    }

    @Test("bold or italic at the start of a line is not a list item")
    func emphasisIsNotList() {
        #expect(MarkdownParser.blocks(in: "**1. Bold** text\n*italic*") == [.text("**1. Bold** text\n*italic*")])
    }

    @Test("rules, quotes, and prose around them")
    func rulesAndQuotes() {
        #expect(
            MarkdownParser.blocks(in: "Intro\n---\n> quoted\n> more\n\n* * *\nEnd") == [
                .text("Intro"),
                .rule,
                .quote("quoted\nmore"),
                .rule,
                .text("End"),
            ])
    }

    @Test("a pipe table with its alignments; rows padded to the header; a lone pipe line is prose")
    func table() {
        let source = "| A | B | C |\n|---|:---:|--:|\n| `x` | y |\n| 1 | a \\| b | 3 |\n\n| not a table |"
        #expect(
            MarkdownParser.blocks(in: source) == [
                .table(
                    header: ["A", "B", "C"],
                    alignments: [.leading, .center, .trailing],
                    rows: [["`x`", "y", ""], ["1", "a | b", "3"]]
                ),
                .text("| not a table |"),
            ])
    }

    @Test("a reply from the goodapps-factory conversation: rules, bold titles, numbered items, code")
    func realReply() {
        let source = """
            Voici la comparaison complète.

            ---

            **Ce que fait goodapps-factory avec Hermes**

            La commande exacte :
            ```
            hermes chat --oneshot
            ```

            ---

            1. **Les `needs-verification`** peuvent être résolus.

            2. **Les model IDs réels** : `claude-opus-5-5`.
            """
        #expect(
            MarkdownParser.blocks(in: source) == [
                .text("Voici la comparaison complète."),
                .rule,
                .text("**Ce que fait goodapps-factory avec Hermes**"),
                .text("La commande exacte :"),
                .code(language: nil, code: "hermes chat --oneshot"),
                .rule,
                .list([
                    MarkdownListItem(number: "1.", text: "**Les `needs-verification`** peuvent être résolus.", level: 0),
                    MarkdownListItem(number: "2.", text: "**Les model IDs réels** : `claude-opus-5-5`.", level: 0),
                ]),
            ])
    }
}
