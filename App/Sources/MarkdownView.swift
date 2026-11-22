import HermesChat
import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Renders a message: headings, lists, quotes, rules, tables and prose with inline Markdown, and fenced code
/// blocks with a copy button. See `MarkdownParser` for the syntax read.
struct MarkdownView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownParser.blocks(in: source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(Self.inline(text))
                        .textSelection(.enabled)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(Self.headingFont(level))
                        .textSelection(.enabled)
                        .padding(.top, level <= 2 ? 6 : 2)
                case .list(let items):
                    ListBlockView(items: items)
                case .quote(let text):
                    Text(Self.inline(text))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(.tertiary)
                                .frame(width: 3)
                        }
                case .rule:
                    Divider()
                        .padding(.vertical, 4)
                case .table(let header, let alignments, let rows):
                    TableBlockView(header: header, alignments: alignments, rows: rows)
                }
            }
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        default: .headline
        }
    }

    /// Inline Markdown only (emphasis, code spans, links). Line breaks are kept.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language ?? "code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    copyToPasteboard(code)
                }
                .labelStyle(.titleAndIcon)
                .font(.caption)
            }
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(UIKit)
            UIPasteboard.general.string = text
        #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// A list: one row per item, with its bullet or number, indented by nesting level.
private struct ListBlockView: View {
    let items: [MarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.number ?? (item.level == 0 ? "•" : "◦"))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(MarkdownView.inline(item.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.level) * 18)
            }
        }
    }
}

/// A table in a grid that scrolls sideways when it is wider than the message. The header is bold and a
/// line separates it from the body.
private struct TableBlockView: View {
    let header: [String]
    let alignments: [MarkdownAlignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column)
                            .fontWeight(.semibold)
                    }
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, column: column)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func cellView(_ cell: String, column: Int) -> some View {
        Text(MarkdownView.inline(cell))
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 260, alignment: Self.frameAlignment(alignments[column]))
            .gridColumnAlignment(Self.horizontalAlignment(alignments[column]))
    }

    private static func frameAlignment(_ alignment: MarkdownAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private static func horizontalAlignment(_ alignment: MarkdownAlignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
