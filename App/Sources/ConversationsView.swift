import HermesAPI
import HermesChat
import SwiftUI

/// Top-level navigation category in the primary sidebar column for Mac and iPad.
enum SidebarFolder: Hashable, Sendable {
    case recents
    case project(String)
}

/// Main screen: adaptive navigation.
/// - On compact widths (iPhone): uses a classic, robust single-column NavigationStack with 100% platform isolation.
/// - On regular widths (iPad, Mac): uses a native, professional Three-Column NavigationSplitView matching Apple Mail/Notes.
struct ConversationsView: View {
    let browser: ConversationBrowser
    /// Edited by the settings sheet.
    let appState: AppState

    @State private var isShowingSettings = false
    /// Why the last action on a conversation failed, shown in an alert.
    @State private var failure: String?

    // Multi-column split view state for macOS / iPadOS
    @State private var selectedFolder: SidebarFolder? = .recents
    @State private var selectedSessionID: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // State for project management in the macOS/iPad sidebar
    @State private var isCreatingProject = false
    @State private var projectName = ""
    @State private var refusedProjectName: String?
    @State private var renamingProjectID: String?
    @State private var draftProjectName = ""
    @State private var deletingProjectID: String?

    // State for conversation search and management in macOS/iPad content column
    @State private var contentSearchQuery = ""
    @State private var renamingSessionID: String?
    @State private var draftSessionTitle = ""
    @State private var deletingSessionID: String?

    // State for repository management in project content column
    @State private var isAddingRepository = false
    @State private var repositoryURL = ""
    @State private var deletingRepositoryID: String?

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || sizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if isCompact {
                iphoneBody
            } else {
                macPadBody
            }
        }
        // ⌘N in the menu bar, see `NewConversationCommand`.
        .focusedSceneValue(\.newConversation, newConversationAction)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(appState: appState, canCancel: true)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Not added to the project",
            isPresented: Binding(
                get: { browser.projectNotice != nil },
                set: { if !$0 { browser.dismissProjectNotice() } }
            ),
            presenting: browser.projectNotice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice)
        }
    }

    // MARK: - iPhone (Single Column NavigationStack)

    private var iphoneBody: some View {
        NavigationStack {
            ConversationListView(browser: browser, failure: $failure)
                .navigationTitle("Conversations")
                .sidebarToolbar(
                    isShowingSettings: $isShowingSettings,
                    isCreating: browser.isCreating,
                    startConversation: { startConversation(inProject: browser.openedProjectID) }
                )
                .navigationDestination(for: String.self) { projectID in
                    ProjectSidebarView(
                        browser: browser,
                        projectID: projectID,
                        startConversation: { startConversation(inProject: projectID) },
                        failure: $failure
                    )
                }
                .navigationDestination(for: SidebarItem.self) { item in
                    if case .session(let sessionID) = item {
                        if let session = browser.remoteSessions.sessions(withIDs: [sessionID]).first ?? browser.remoteSessions.sessions.first(where: { $0.id == sessionID }) {
                            ChatView(transcript: browser.remoteSessions.transcript(for: session))
                                .id(sessionID)
                                .onAppear {
                                    browser.openRemote(session)
                                }
                        }
                    }
                }
        }
    }

    // MARK: - macOS / iPadOS (Three-Column NavigationSplitView)

    private var macPadBody: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            splitSidebarColumn
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            splitContentColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            splitDetailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            columnVisibility = .all
        }
        .task(id: ObjectIdentifier(browser)) {
            await browser.reloadSessions()
        }
        .refreshable {
            await browser.reloadSessions()
        }
        .onChange(of: selectedFolder) { _, newFolder in
            handleFolderSelectionChange(newFolder)
        }
        .onChange(of: selectedSessionID) { _, newSessionID in
            handleSessionSelectionChange(newSessionID)
        }
        .onChange(of: browser.openedRemote?.activeSessionID) { _, newActiveID in
            if selectedSessionID != newActiveID {
                selectedSessionID = newActiveID
            }
        }
        .projectAlerts(
            isCreatingProject: $isCreatingProject,
            projectName: $projectName,
            createProject: createProject,
            refusedProjectName: $refusedProjectName,
            renamingProjectID: $renamingProjectID,
            draftProjectName: $draftProjectName,
            renameProject: renameProject,
            deletingProjectID: $deletingProjectID,
            deleteProject: deleteProject
        )
        .conversationAlerts(
            renamingSessionID: $renamingSessionID,
            draftSessionTitle: $draftSessionTitle,
            renameSession: renameSession,
            deletingSessionID: $deletingSessionID,
            deleteSession: deleteSession
        )
        .repositoryAlerts(
            isAddingRepository: $isAddingRepository,
            repositoryURL: $repositoryURL,
            addRepository: addRepository,
            deletingRepositoryID: $deletingRepositoryID,
            deleteRepository: deleteRepository
        )
    }

    // MARK: Column 1 - Primary Sidebar (Folders)

    private var splitSidebarColumn: some View {
        List(selection: $selectedFolder) {
            Section {
                Label("Recents", systemImage: "clock")
                    .tag(SidebarFolder.recents)
            }
            if let projects = browser.projects {
                Section {
                    ForEach(projects.projects) { project in
                        Label(project.name, systemImage: "folder")
                            .tag(SidebarFolder.project(project.id))
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") {
                                    draftProjectName = project.name
                                    renamingProjectID = project.id
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    deletingProjectID = project.id
                                }
                            }
                    }
                } header: {
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
            }
        }
        .navigationTitle("Hermes")
        .toolbar {
            ToolbarItem(placement: .leadingAction) {
                Button("Settings", systemImage: "gearshape") {
                    isShowingSettings = true
                }
            }
        }
    }

    // MARK: Column 2 - Secondary Content List (Conversations)

    @ViewBuilder
    private var splitContentColumn: some View {
        switch selectedFolder {
        case .project(let projectID):
            if let project = browser.projects?.project(id: projectID) {
                projectContentView(project)
            } else {
                ContentUnavailableView("Project not found", systemImage: "folder.badge.minus")
            }
        case .recents, nil:
            recentsContentView
        }
    }

    private var recentsContentView: some View {
        List(selection: $selectedSessionID) {
            ForEach(matchingRecents) { session in
                conversationRow(session)
            }
            RemoteStatusRows(list: browser.remoteSessions)
                .listRowSeparator(.hidden)
        }
        .navigationTitle("Recents")
        .searchable(text: $contentSearchQuery, placement: .automatic, prompt: "Search")
        .overlay {
            if matchingRecents.isEmpty, !contentSearchQuery.isEmpty {
                ContentUnavailableView.search(text: contentSearchQuery)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New conversation", systemImage: "square.and.pencil") {
                    startConversation(inProject: nil)
                }
                .disabled(browser.isCreating)
            }
        }
    }

    private func projectContentView(_ project: Project) -> some View {
        let projectSessions = browser.conversations(in: project)
        return List(selection: $selectedSessionID) {
            Section("Repositories") {
                ForEach(project.repositories) { repo in
                    Label(repo.name, systemImage: "arrow.triangle.branch")
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                deletingRepositoryID = repo.id
                            }
                        }
                }
                Button {
                    repositoryURL = ""
                    isAddingRepository = true
                } label: {
                    Label("Add repository", systemImage: "plus")
                }
            }
            Section("Conversations") {
                if projectSessions.isEmpty {
                    if browser.remoteSessions.knowsAll(project.conversationIDs) {
                        Text("No conversations")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    ForEach(projectSessions) { session in
                        conversationRow(session)
                    }
                }
            }
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New conversation", systemImage: "square.and.pencil") {
                    startConversation(inProject: project.id)
                }
                .disabled(browser.isCreating)
            }
        }
        .task(id: project.conversationIDs) {
            await browser.loadConversations(in: project)
        }
    }

    private func conversationRow(_ session: RemoteSession) -> some View {
        Label {
            Text(session.displayTitle)
        } icon: {
            Image(systemName: ConversationListView.icon(for: session.kind))
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
        .listItemTint(.monochrome)
        .tag(session.id)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                draftSessionTitle = session.title ?? ""
                renamingSessionID = session.id
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                deletingSessionID = session.id
            }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
                deletingSessionID = session.id
            }
            Button("Rename", systemImage: "pencil") {
                draftSessionTitle = session.title ?? ""
                renamingSessionID = session.id
            }
            .tint(.indigo)
        }
    }

    // MARK: Column 3 - Tertiary Detail (Chat)

    private var splitDetailColumn: some View {
        Group {
            if let transcript = browser.openedRemote {
                ChatView(transcript: transcript)
                    .id(transcript.sessionID)
            } else if browser.isCreating {
                ProgressView("Starting the conversation…")
            } else {
                ContentUnavailableView {
                    Label("No conversation open", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Pick a conversation in the list, or start a new one.")
                } actions: {
                    Button("New conversation") {
                        startConversation(inProject: browser.openedProjectID)
                    }
                }
            }
        }
    }

    // MARK: - Helpers & Data

    private var matchingRecents: [RemoteSession] {
        browser.recentSessions.matching(contentSearchQuery)
    }

    private func handleFolderSelectionChange(_ newFolder: SidebarFolder?) {
        switch newFolder {
        case .project(let projectID):
            browser.openProject(projectID)
            selectedSessionID = nil
        case .recents, nil:
            if browser.openedProjectID != nil {
                browser.select(nil)
                selectedSessionID = nil
            }
        }
    }

    private func handleSessionSelectionChange(_ newSessionID: String?) {
        guard let newSessionID else {
            return
        }
        if let session = browser.remoteSessions.sessions(withIDs: [newSessionID]).first ?? browser.remoteSessions.sessions.first(where: { $0.id == newSessionID }) {
            let currentProjectID = browser.openedProjectID
            browser.openRemote(session, inProject: currentProjectID)
        }
    }

    private var newConversationAction: (@MainActor () -> Void)? {
        guard !browser.isCreating, !isShowingSettings else { return nil }
        let projectID = browser.openedProjectID
        return { startConversation(inProject: projectID) }
    }

    private func startConversation(inProject projectID: String?) {
        Task {
            do {
                try await browser.createConversation(inProject: projectID)
            } catch {
                failure = "The conversation could not be started. \(Self.reason(error))"
            }
        }
    }

    // MARK: Actions for Projects, Conversations, Repositories

    private func createProject() {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                let project = try await browser.createProject(named: name)
                selectedFolder = .project(project.id)
            } catch let error as ProjectError {
                switch error {
                case .nameTaken, .invalidName:
                    refusedProjectName = error.errorDescription
                default:
                    failure = "The project could not be created. \(ConversationListView.reason(error))"
                }
            } catch {
                failure = "The project could not be created. \(ConversationListView.reason(error))"
            }
        }
    }

    private func renameProject(_ projectID: String, to name: String) {
        Task {
            do {
                try await browser.renameProject(projectID, to: name)
            } catch {
                failure = "The project could not be renamed. \(ConversationListView.reason(error))"
            }
        }
    }

    private func deleteProject(_ projectID: String) {
        Task {
            do {
                try await browser.deleteProject(projectID)
                if selectedFolder == .project(projectID) {
                    selectedFolder = .recents
                }
            } catch {
                failure = "The project could not be deleted. \(ConversationListView.reason(error))"
            }
        }
    }

    private func renameSession(_ sessionID: String, to title: String) {
        Task {
            do {
                try await browser.renameSession(sessionID, to: title)
            } catch {
                failure = "The conversation could not be renamed. \(Self.reason(error))"
            }
        }
    }

    private func deleteSession(_ sessionID: String) {
        Task {
            do {
                try await browser.deleteSession(sessionID)
                if selectedSessionID == sessionID {
                    selectedSessionID = nil
                }
            } catch {
                failure = "The conversation could not be deleted. \(Self.reason(error))"
            }
        }
    }

    private func addRepository(url: String) {
        guard let projectID = browser.openedProjectID else { return }
        Task {
            do {
                try await browser.attachRepository(url: url, to: projectID)
            } catch {
                failure = "The repository could not be attached. \(ConversationListView.reason(error))"
            }
        }
    }

    private func deleteRepository(_ repositoryID: String) {
        guard let projectID = browser.openedProjectID else { return }
        Task {
            do {
                try await browser.detachRepository(repositoryID, from: projectID)
            } catch {
                failure = "The repository could not be removed. \(ConversationListView.reason(error))"
            }
        }
    }

    static func reason(_ error: any Error) -> String {
        HermesAPIError.from(error).errorDescription ?? "The request failed."
    }
}

extension View {
    fileprivate func sidebarToolbar(
        isShowingSettings: Binding<Bool>,
        isCreating: Bool,
        startConversation: @escaping () -> Void
    ) -> some View {
        self.toolbar {
            ToolbarItem(placement: .leadingAction) {
                Button("Settings", systemImage: "gearshape") {
                    isShowingSettings.wrappedValue = true
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New conversation", systemImage: "square.and.pencil", action: startConversation)
                    .disabled(isCreating)
            }
        }
    }

    fileprivate func projectAlerts(
        isCreatingProject: Binding<Bool>,
        projectName: Binding<String>,
        createProject: @escaping () -> Void,
        refusedProjectName: Binding<String?>,
        renamingProjectID: Binding<String?>,
        draftProjectName: Binding<String>,
        renameProject: @escaping (String, String) -> Void,
        deletingProjectID: Binding<String?>,
        deleteProject: @escaping (String) -> Void
    ) -> some View {
        self
            .alert("New project", isPresented: isCreatingProject) {
                TextField("Name", text: projectName)
                Button("Create", action: createProject)
                Button("Cancel", role: .cancel) {
                    projectName.wrappedValue = ""
                }
            }
            .alert(
                "The project could not be created",
                isPresented: Binding(
                    get: { refusedProjectName.wrappedValue != nil },
                    set: { if !$0 { refusedProjectName.wrappedValue = nil } }
                ),
                presenting: refusedProjectName.wrappedValue
            ) { _ in
                Button("OK") {
                    isCreatingProject.wrappedValue = true
                }
            } message: { reason in
                Text(reason)
            }
            .alert(
                "Rename project",
                isPresented: Binding(
                    get: { renamingProjectID.wrappedValue != nil },
                    set: { if !$0 { renamingProjectID.wrappedValue = nil } }
                )
            ) {
                TextField("Name", text: draftProjectName)
                Button("Save") {
                    if let id = renamingProjectID.wrappedValue {
                        renameProject(id, draftProjectName.wrappedValue)
                    }
                    renamingProjectID.wrappedValue = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingProjectID.wrappedValue = nil
                }
            }
            .confirmationDialog(
                "Delete this project?",
                isPresented: Binding(
                    get: { deletingProjectID.wrappedValue != nil },
                    set: { if !$0 { deletingProjectID.wrappedValue = nil } }
                ),
                titleVisibility: .visible,
                presenting: deletingProjectID.wrappedValue
            ) { projectID in
                Button("Delete", role: .destructive) {
                    deleteProject(projectID)
                }
            } message: { _ in
                Text("Its conversations will stay in Recents.")
            }
    }

    fileprivate func conversationAlerts(
        renamingSessionID: Binding<String?>,
        draftSessionTitle: Binding<String>,
        renameSession: @escaping (String, String) -> Void,
        deletingSessionID: Binding<String?>,
        deleteSession: @escaping (String) -> Void
    ) -> some View {
        self
            .alert(
                "Rename conversation",
                isPresented: Binding(
                    get: { renamingSessionID.wrappedValue != nil },
                    set: { if !$0 { renamingSessionID.wrappedValue = nil } }
                )
            ) {
                TextField("Title", text: draftSessionTitle)
                Button("Save") {
                    if let id = renamingSessionID.wrappedValue {
                        renameSession(id, draftSessionTitle.wrappedValue)
                    }
                    renamingSessionID.wrappedValue = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingSessionID.wrappedValue = nil
                }
            }
            .confirmationDialog(
                "Delete this conversation?",
                isPresented: Binding(
                    get: { deletingSessionID.wrappedValue != nil },
                    set: { if !$0 { deletingSessionID.wrappedValue = nil } }
                ),
                titleVisibility: .visible,
                presenting: deletingSessionID.wrappedValue
            ) { sessionID in
                Button("Delete", role: .destructive) {
                    deleteSession(sessionID)
                }
            } message: { _ in
                Text("It is deleted from your Hermes instance, with all its messages.")
            }
    }

    fileprivate func repositoryAlerts(
        isAddingRepository: Binding<Bool>,
        repositoryURL: Binding<String>,
        addRepository: @escaping (String) -> Void,
        deletingRepositoryID: Binding<String?>,
        deleteRepository: @escaping (String) -> Void
    ) -> some View {
        self
            .alert("Add repository", isPresented: isAddingRepository) {
                TextField("GitHub URL", text: repositoryURL)
                Button("Add") {
                    let trimmed = repositoryURL.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        addRepository(trimmed)
                    }
                    repositoryURL.wrappedValue = ""
                }
                Button("Cancel", role: .cancel) {
                    repositoryURL.wrappedValue = ""
                }
            }
            .confirmationDialog(
                "Remove this repository from the project?",
                isPresented: Binding(
                    get: { deletingRepositoryID.wrappedValue != nil },
                    set: { if !$0 { deletingRepositoryID.wrappedValue = nil } }
                ),
                titleVisibility: .visible,
                presenting: deletingRepositoryID.wrappedValue
            ) { repoID in
                Button("Remove", role: .destructive) {
                    deleteRepository(repoID)
                }
            } message: { _ in
                Text("The repository stays on GitHub.")
            }
    }
}
