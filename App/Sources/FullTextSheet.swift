import HermesChat
import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// A button under a message cut by `LongText.preview(of:)`: says how long the message is and opens it whole.
struct FullTextButton: View {
    let text: String

    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing = true
        } label: {
            Label("Show the full message · \(text.count.formatted()) characters", systemImage: "text.alignleft")
                .font(.footnote.weight(.medium))
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $isShowing) {
            FullTextSheet(text: text)
        }
    }
}

/// A long message, whole. It is drawn in pieces in a lazy stack: one `Text` this long would draw nothing.
struct FullTextSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss
    @State private var chunks: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                        Text(chunk)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("\(text.count.formatted()) characters")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        #if canImport(UIKit)
                            UIPasteboard.general.string = text
                        #elseif canImport(AppKit)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        #endif
                    }
                }
            }
        }
        .task {
            chunks = LongText.chunks(of: text)
        }
    }
}
