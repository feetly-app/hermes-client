import HermesAPI
import HermesChat
import SwiftUI

/// Sidebar: the conversations, most recently used first, one line each (an icon for its kind and the title).
/// Each is a session on the Hermes instance. Every row can be renamed or deleted, from its context menu or a
/// swipe. A search field narrows the list by title.
struct ConversationListView: View {
    let browser: ConversationBrowser
    /// Set to the reason when a rename or a delete fails.
    @Binding var failure: String?

    /// The id of the session being renamed, and the title being typed.
    @State private var renaming: String?
    @State private var draftTitle = ""
    /// The id of the session waiting for the delete confirmation.
    @State private var deleting: String?
    @State private var query = ""

    var body: some View {
        List(selection: selection) {
            if !sessions.isEmpty {
                Section("Recents") {
                    ForEach(sessions) { session in
                        row(session)
                    }
                }
            }
            RemoteStatusRows(list: browser.remoteSessions)
                .listRowSeparator(.hidden)
        }
        .sobreListStyle()
        // In the list itself, as in Settings or Notes: under the large title on iOS, at the top of the
        // sidebar on macOS. Not the toolbar search button, which hides the field until it is tapped.
        .searchable(text: $query, placement: Self.searchPlacement, prompt: "Search")
        .overlay {
            if sessions.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task {
            await browser.reloadSessions()
        }
        .refreshable {
            await browser.reloadSessions()
        }
        .alert("Rename conversation", isPresented: isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Save") {
                if let renaming {
                    rename(renaming, to: draftTitle)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) {
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: isDeleting,
            titleVisibility: .visible,
            presenting: deleting
        ) { sessionID in
            Button("Delete", role: .destructive) {
                delete(sessionID)
            }
        } message: { _ in
            Text("It is deleted from your Hermes instance, with all its messages.")
        }
    }

    /// The sessions, most recently used first, narrowed to the titles that match the search query (case and
    /// accents ignored). The search covers the sessions loaded so far.
    private var sessions: [RemoteSession] {
        browser.remoteSessions.recentFirst.matching(query)
    }

    /// One line: the icon of the session kind and its title, truncated at the end. The icon takes the color
    /// of the text, not the accent color: `listItemTint(.monochrome)` is what a macOS sidebar honours, the
    /// foreground style is what an iOS list does.
    private func row(_ session: RemoteSession) -> some View {
        Label {
            Text(session.displayTitle)
        } icon: {
            Image(systemName: Self.icon(for: session.kind))
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
        .listItemTint(.monochrome)
        .tag(session.id)
        .listRowSeparator(.hidden)
        .modifier(RowActions(
            onRename: { startRenaming(session.id, title: session.title ?? "") },
            onDelete: { deleting = session.id }
        ))
    }

    private static var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
            .navigationBarDrawer(displayMode: .always)
        #else
            .sidebar
        #endif
    }

    private static func icon(for kind: SessionKind) -> String {
        switch kind {
        case .chat: "bubble.left"
        case .scheduled: "clock"
        }
    }

    private func startRenaming(_ sessionID: String, title: String) {
        draftTitle = title
        renaming = sessionID
    }

    private func rename(_ sessionID: String, to title: String) {
        Task {
            do {
                try await browser.renameSession(sessionID, to: title)
            } catch {
                failure = "The conversation could not be renamed. \(ConversationsView.reason(error))"
            }
        }
    }

    private func delete(_ sessionID: String) {
        Task {
            do {
                try await browser.deleteSession(sessionID)
            } catch {
                failure = "The conversation could not be deleted. \(ConversationsView.reason(error))"
            }
        }
    }

    /// One selection for every row. On compact widths the split view collapses into a stack, and only
    /// the list selection pushes the detail: a row outside it never opens.
    private var selection: Binding<String?> {
        Binding(
            get: { browser.selectedSessionID },
            set: { browser.selectSession($0) }
        )
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

extension View {
    /// A plain list on iOS, as in the Claude app: rows straight on the screen background, without the grouped
    /// cards. macOS keeps its native sidebar.
    @ViewBuilder
    fileprivate func sobreListStyle() -> some View {
        #if os(iOS)
            listStyle(.plain)
        #else
            self
        #endif
    }
}

/// Rename and delete, in the context menu and as trailing swipe actions.
private struct RowActions: ViewModifier {
    let onRename: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Rename", systemImage: "pencil", action: onRename)
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                Button("Rename", systemImage: "pencil", action: onRename)
                    .tint(.indigo)
            }
    }
}

/// Footer of the sidebar for the Hermes instance: a loading indicator, an error with retry, or "Load more".
struct RemoteStatusRows: View {
    let list: RemoteSessionList

    var body: some View {
        switch list.state {
        case .loading:
            ProgressView()
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await list.reload() }
                }
            }
        case .idle, .loaded:
            if list.hasMore {
                Button("Load more") {
                    Task { await list.loadNextPage() }
                }
            }
        }
    }
}
