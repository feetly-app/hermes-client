import HermesAPI
import HermesChat
import SwiftUI

/// The screen of a project, navigated inside the sidebar (navigation bar) of NavigationSplitView:
/// its repositories (primary section) and its conversations (secondary section) in a single narrow List.
///
/// Selecting a conversation opens the ChatView in the detail column on the right.
struct ProjectSidebarView: View {
    let browser: ConversationBrowser
    let projectID: String
    /// Starts a conversation in this project.
    let startConversation: () -> Void
    /// Set to the reason when an action fails.
    @Binding var failure: String?
    /// When provided (Mac / iPad split view), tapping a conversation selects it instead of pushing.
    var onSelectSession: ((RemoteSession) -> Void)? = nil

    /// The id of the session being renamed, and the title being typed.
    @State private var renaming: String?
    @State private var draftTitle = ""
    /// The id of the session waiting for the delete confirmation.
    @State private var deleting: String?
    @State private var isRenamingProject = false
    @State private var draftProjectName = ""
    @State private var isDeletingProject = false
    @State private var isAddingRepository = false
    @State private var repositoryURL = ""
    @State private var deletingRepository: String?

    var project: Project? {
        browser.projects?.project(id: projectID)
    }

    var body: some View {
        Group {
            if let project {
                List {
                    repositoriesSection(project)
                    conversationsSection(project)
                }
                .navigationTitle(project.name)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New conversation", systemImage: "square.and.pencil", action: startConversation)
                            .disabled(browser.isCreating)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("More", systemImage: "ellipsis") {
                            Button("Rename project", systemImage: "pencil") {
                                draftProjectName = project.name
                                isRenamingProject = true
                            }
                            Button("Delete project", systemImage: "trash", role: .destructive) {
                                isDeletingProject = true
                            }
                        }
                    }
                }
                .alert("Rename project", isPresented: $isRenamingProject) {
                    TextField("Name", text: $draftProjectName)
                    Button("Save") {
                        renameProject(to: draftProjectName)
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog(
                    "Delete this project?",
                    isPresented: $isDeletingProject,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive, action: deleteProject)
                } message: {
                    Text("Its conversations are kept on your Hermes instance and move to Recents.")
                }
            } else {
                ContentUnavailableView("Project not found", systemImage: "folder.badge.questionmark")
            }
        }
        .onAppear {
            browser.openProject(projectID)
        }
        .onDisappear {
            if browser.openedProjectID == projectID {
                browser.openProject("") // clears openedProjectID, closing the project
            }
        }
        // Sync project state
        .onChange(of: project) { _, newValue in
            if newValue == nil {
                browser.select(nil)
            }
        }
        .task(id: project?.conversationIDs) {
            if let project {
                await browser.loadConversations(in: project)
            }
        }
    }

    private func repositoriesSection(_ project: Project) -> some View {
        Section {
            if project.repositories.isEmpty {
                Text("No repositories")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(project.repositories) { repository in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(repository.name, systemImage: "shippingbox")
                        Text(repository.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .lineLimit(1)
                    .contextMenu {
                        Button("Detach", systemImage: "trash", role: .destructive) {
                            deletingRepository = repository.id
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Detach", systemImage: "trash", role: .destructive) {
                            deletingRepository = repository.id
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Repositories")
                Spacer()
                Button {
                    repositoryURL = ""
                    isAddingRepository = true
                } label: {
                    Label("Add repository", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Add repository")
            }
        }
        .alert("Add repository", isPresented: $isAddingRepository) {
            #if os(iOS)
            TextField("Repository URL", text: $repositoryURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
            #else
            TextField("Repository URL", text: $repositoryURL)
                .autocorrectionDisabled()
            #endif
            Button("Add") {
                addRepository(url: repositoryURL)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Detach this repository?",
            isPresented: isDeletingRepository,
            titleVisibility: .visible,
            presenting: deletingRepository
        ) { repositoryID in
            Button("Detach", role: .destructive) {
                detachRepository(repositoryID)
            }
        } message: { _ in
            Text("It is detached from this project. The repository stays unchanged.")
        }
    }

    private var sessions: [RemoteSession] {
        if let project {
            return browser.conversations(in: project)
        }
        return []
    }

    private func conversationsSection(_ project: Project) -> some View {
        Section("Conversations") {
            if sessions.isEmpty {
                if browser.remoteSessions.knowsAll(project.conversationIDs) {
                    Text("No conversations")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                ForEach(sessions) { session in
                    Group {
                        if let onSelectSession {
                            Button {
                                onSelectSession(session)
                            } label: {
                                projectRowContent(session)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink(value: SidebarItem.session(session.id)) {
                                projectRowContent(session)
                            }
                        }
                    }
                    .lineLimit(1)
                    .modifier(RowActions(
                        onRename: {
                            draftTitle = session.title ?? ""
                            renaming = session.id
                        },
                        onDelete: { deleting = session.id }
                    ))
                }
            }
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

    private func projectRowContent(_ session: RemoteSession) -> some View {
        let isSelected = browser.selectedSessionID == session.id
        return Label {
            Text(session.displayTitle)
        } icon: {
            Image(systemName: ConversationListView.icon(for: session.kind))
        }
        .lineLimit(1)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            isSelected && onSelectSession != nil ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    // MARK: Actions

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

    private func renameProject(to name: String) {
        Task {
            do {
                try await browser.renameProject(projectID, to: name)
            } catch {
                failure = "The project could not be renamed. \(ConversationListView.reason(error))"
            }
        }
    }

    private func deleteProject() {
        Task {
            do {
                try await browser.deleteProject(projectID)
            } catch {
                failure = "The project could not be deleted. \(ConversationListView.reason(error))"
            }
        }
    }

    private func addRepository(url: String) {
        Task {
            do {
                try await browser.attachRepository(url: url, to: projectID)
            } catch {
                failure = "The repository could not be attached. \(ConversationListView.reason(error))"
            }
        }
    }

    private func detachRepository(_ repositoryID: String) {
        Task {
            do {
                try await browser.detachRepository(repositoryID, from: projectID)
            } catch {
                failure = "The repository could not be detached. \(ConversationListView.reason(error))"
            }
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var isDeletingRepository: Binding<Bool> {
        Binding(get: { deletingRepository != nil }, set: { if !$0 { deletingRepository = nil } })
     }
}
