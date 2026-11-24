import HermesAPI
import HermesChat
import SwiftUI

/// Sidebar: the Projects of the sidecar, then Recents, the conversations in no project, most recently used
/// first, one line each (an icon for its kind and the title). Each conversation is a session on the Hermes
/// instance. Every row can be renamed or deleted, from its context menu or a swipe. A search field narrows
/// Recents by title and Projects by name.
///
/// Without a sidecar there are no projects: the Projects section is hidden and Recents lists everything.
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

    /// The name alert of a new project, and the name typed. The name stays when the sidecar refuses it.
    @State private var isCreatingProject = false
    @State private var projectName = ""
    /// Why the sidecar refused the name; the name alert opens again once it is dismissed.
    @State private var refusedProjectName: String?
    /// The id of the project being renamed, and the name being typed.
    @State private var renamingProject: String?
    @State private var draftProjectName = ""
    /// The id of the project waiting for the delete confirmation.
    @State private var deletingProject: String?

    var body: some View {
        List(selection: selection) {
            if let projects = browser.projects, !isSearching || !matchingProjects.isEmpty {
                Section {
                    ForEach(matchingProjects) { project in
                        projectRow(project)
                    }
                    if matchingProjects.isEmpty {
                        ProjectStatusRow(list: projects)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    projectsHeader
                }
            }
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
        // In the list itself, as in Mail or Notes: on iOS hidden under the large title until the list is
        // pulled down, at the top of the sidebar on macOS. Not the toolbar search button.
        .searchable(text: $query, placement: Self.searchPlacement, prompt: "Search")
        .overlay {
            if sessions.isEmpty, matchingProjects.isEmpty, isSearching {
                ContentUnavailableView.search(text: query)
            }
        }
        // Again for a new browser, after the connection settings changed: projects and sessions come from it.
        .task(id: ObjectIdentifier(browser)) {
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
        .alert("New project", isPresented: $isCreatingProject) {
            TextField("Name", text: $projectName)
            Button("Create", action: createProject)
            Button("Cancel", role: .cancel) {
                projectName = ""
            }
        }
        .alert(
            "The project could not be created",
            isPresented: Binding(get: { refusedProjectName != nil }, set: { if !$0 { refusedProjectName = nil } }),
            presenting: refusedProjectName
        ) { _ in
            // Back to the name alert, with the name typed.
            Button("OK") {
                isCreatingProject = true
            }
        } message: { reason in
            Text(reason)
        }
        .alert("Rename project", isPresented: isRenamingProject) {
            TextField("Name", text: $draftProjectName)
            Button("Save") {
                if let renamingProject {
                    renameProject(renamingProject, to: draftProjectName)
                }
                renamingProject = nil
            }
            Button("Cancel", role: .cancel) {
                renamingProject = nil
            }
        }
        .confirmationDialog(
            "Delete this project?",
            isPresented: isDeletingProject,
            titleVisibility: .visible,
            presenting: deletingProject
        ) { projectID in
            Button("Delete", role: .destructive) {
                deleteProject(projectID)
            }
        } message: { _ in
            Text("Its conversations are kept on your Hermes instance and move to Recents.")
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The conversations in no project, most recently used first, narrowed to the titles that match the search
    /// query (case and accents ignored). The search covers the sessions loaded so far.
    private var sessions: [RemoteSession] {
        browser.recentSessions.matching(query)
    }

    /// The projects in the sidecar order (by name), narrowed to the names that match the search query. The
    /// conversations inside projects are not searched.
    private var matchingProjects: [Project] {
        browser.projects?.projects.matching(query) ?? []
    }

    private var projectsHeader: some View {
        HStack {
            Text("Projects")
            Spacer()
            Button {
                projectName = ""
                isCreatingProject = true
            } label: {
                Label("New project", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("New project")
        }
    }

    /// One line: a folder and the project name.
    private func projectRow(_ project: Project) -> some View {
        NavigationLink(value: project) {
            Label {
                Text(project.name)
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(.primary)
            }
            .lineLimit(1)
            .listItemTint(.monochrome)
        }
        .listRowSeparator(.hidden)
        .modifier(RowActions(
            onRename: {
                draftProjectName = project.name
                renamingProject = project.id
            },
            onDelete: { deletingProject = project.id }
        ))
    }

    /// One line: the icon of the session kind and its title, truncated at the end. The icon takes the color
    /// of the text, not the accent color: `listItemTint(.monochrome)` is what a macOS sidebar honours, the
    /// foreground style is what an iOS list does.
    private func row(_ session: RemoteSession) -> some View {
        NavigationLink(value: SidebarItem.session(session.id)) {
            Label {
                Text(session.displayTitle)
            } icon: {
                Image(systemName: Self.icon(for: session.kind))
                    .foregroundStyle(.primary)
            }
            .lineLimit(1)
            .listItemTint(.monochrome)
        }
        .listRowSeparator(.hidden)
        .modifier(RowActions(
            onRename: { startRenaming(session.id, title: session.title ?? "") },
            onDelete: { deleting = session.id }
        ))
    }

    private static var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
            .navigationBarDrawer(displayMode: .automatic)
        #else
            .sidebar
        #endif
    }

    static func icon(for kind: SessionKind) -> String {
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

    /// Creates the project and opens it. A name the sidecar refuses (taken, blank, too long) shows why, then
    /// the name alert again with the name typed.
    private func createProject() {
        let name = projectName
        Task {
            do {
                try await browser.createProject(named: name)
                projectName = ""
            } catch let error as ProjectError where error.isNameRefusal {
                refusedProjectName = Self.reason(error)
            } catch {
                failure = "The project could not be created. \(Self.reason(error))"
            }
        }
    }

    private func renameProject(_ projectID: String, to name: String) {
        Task {
            do {
                try await browser.renameProject(projectID, to: name)
            } catch {
                failure = "The project could not be renamed. \(Self.reason(error))"
            }
        }
    }

    private func deleteProject(_ projectID: String) {
        Task {
            do {
                try await browser.deleteProject(projectID)
            } catch {
                failure = "The project could not be deleted. \(Self.reason(error))"
            }
        }
    }

    /// The user-facing reason of a project error.
    static func reason(_ error: any Error) -> String {
        ProjectError.from(error).errorDescription ?? "The request failed."
    }

    /// One selection for every row, projects and conversations. On compact widths the split view collapses
    /// into a stack, and only the list selection pushes the detail: a row outside it never opens.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if case .project = browser.selection {
                    return nil
                }
                return browser.selection
            },
            set: { browser.select($0) }
        )
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var isRenamingProject: Binding<Bool> {
        Binding(get: { renamingProject != nil }, set: { if !$0 { renamingProject = nil } })
    }

    private var isDeletingProject: Binding<Bool> {
        Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } })
    }
}

extension ProjectError {
    /// `true` when the sidecar refused the name itself: the user can type another one.
    fileprivate var isNameRefusal: Bool {
        switch self {
        case .nameTaken, .invalidName: true
        default: false
        }
    }
}

/// The Projects section when it lists no project: loading, the error with Retry (Recents then shows every
/// conversation), or the empty state.
private struct ProjectStatusRow: View {
    let list: ProjectList

    var body: some View {
        switch list.state {
        case .idle, .loading:
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
        case .loaded:
            Text("No projects yet")
                .foregroundStyle(.secondary)
        }
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
struct RowActions: ViewModifier {
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
