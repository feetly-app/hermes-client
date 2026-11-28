import HermesAPI
import HermesChat
import SwiftUI

/// Main screen: adaptive navigation, driven by what the browser has open.
///
/// - Compact width (iPhone, narrow iPad window): a single `NavigationStack`. The list, then a project screen,
///   then a chat.
/// - Regular width (iPad, Mac): a two-column `NavigationSplitView`. The sidebar holds the list and, pushed in
///   it, a project screen; the detail column shows the open conversation.
///
/// The browser (`openedProjectID`, the open transcript) is the single source of truth. Each layout keeps a path
/// of `SidebarItem`s: a change of path opens or closes things in the browser, and a change in the browser (a new
/// conversation, a new or deleted project, a fork) rebuilds the paths. Both directions converge, so they do not
/// loop.
struct ConversationsView: View {
    let browser: ConversationBrowser
    /// Edited by the settings sheet.
    let appState: AppState

    @State private var isShowingSettings = false
    /// Why the last action on a conversation failed, shown in an alert.
    @State private var failure: String?

    /// Compact layout: the whole stack, an optional project then an optional conversation.
    @State private var stackPath: [SidebarItem] = []
    /// Regular layout: the sidebar stack, the open project at most. The conversation shows in the detail column.
    @State private var sidebarPath: [SidebarItem] = []

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isCompact: Bool {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .phone || sizeClass == .compact
        #else
            false
        #endif
    }

    var body: some View {
        Group {
            if isCompact {
                compactBody
            } else {
                splitBody
            }
        }
        // Once per browser (a new one comes with new connection settings), not each time the list reappears.
        .task(id: ObjectIdentifier(browser)) {
            await browser.reloadSessions()
        }
        .onAppear(perform: syncPathsFromBrowser)
        .onChange(of: isCompact) { syncPathsFromBrowser() }
        .onChange(of: browser.openedProjectID) { syncPathsFromBrowser() }
        .onChange(of: browser.selectedSessionID) { syncPathsFromBrowser() }
        .onChange(of: stackPath) { _, path in
            if isCompact { apply(path) }
        }
        .onChange(of: sidebarPath) { _, path in
            if !isCompact { apply(path) }
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

    // MARK: - Compact (iPhone)

    private var compactBody: some View {
        NavigationStack(path: $stackPath) {
            ConversationListView(browser: browser, failure: $failure)
                .navigationTitle("Conversations")
                .sidebarToolbar(
                    isShowingSettings: $isShowingSettings,
                    isCreating: browser.isCreating,
                    startConversation: { startConversation(inProject: browser.openedProjectID) }
                )
                .navigationDestination(for: SidebarItem.self) { item in
                    switch item {
                    case .project(let projectID):
                        projectScreen(projectID, onSelectSession: nil)
                    case .session(let sessionID):
                        OpenConversationView(browser: browser, sessionID: sessionID)
                    }
                }
        }
    }

    // MARK: - Regular (iPad, Mac)

    private var splitBody: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
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
                    .disabled(browser.isCreating)
                }
            }
        }
    }

    /// The conversation list, or the open project's screen. On iOS the project is pushed on a stack. On macOS
    /// a List pushed in a sidebar stack is never drawn, so the sidebar swaps its content instead, with a back
    /// row at its top (⌘[).
    @ViewBuilder
    private var sidebar: some View {
        #if os(macOS)
            if let projectID = sidebarPath.last?.projectID {
                projectScreen(projectID) { browser.openRemote($0, inProject: projectID) }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Button {
                            sidebarPath = []
                        } label: {
                            Label("Conversations", systemImage: "chevron.backward")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Back to the conversations (⌘[)")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .id(projectID)
            } else {
                conversationList(onOpenProject: { sidebarPath = [.project($0)] })
            }
        #else
            NavigationStack(path: $sidebarPath) {
                conversationList(onOpenProject: nil)
                    .navigationDestination(for: SidebarItem.self) { item in
                        if case .project(let projectID) = item {
                            projectScreen(projectID) { browser.openRemote($0, inProject: projectID) }
                        }
                    }
            }
        #endif
    }

    private func conversationList(onOpenProject: ((String) -> Void)?) -> some View {
        ConversationListView(
            browser: browser,
            failure: $failure,
            onSelectSession: { browser.openRemote($0) },
            onOpenProject: onOpenProject
        )
        .navigationTitle("Conversations")
        .sidebarToolbar(
            isShowingSettings: $isShowingSettings,
            isCreating: browser.isCreating,
            startConversation: { startConversation(inProject: browser.openedProjectID) }
        )
    }

    private func projectScreen(_ projectID: String, onSelectSession: ((RemoteSession) -> Void)?) -> some View {
        ProjectSidebarView(
            browser: browser,
            projectID: projectID,
            startConversation: { startConversation(inProject: projectID) },
            failure: $failure,
            onSelectSession: onSelectSession
        )
    }

    // MARK: - Navigation state

    /// Opens in the browser what a path shows: the last project in it, and in the compact stack the last
    /// conversation. Leaving a chat closes the conversation, leaving a project screen closes the project.
    private func apply(_ path: [SidebarItem]) {
        let projectID = path.lazy.compactMap(\.projectID).last
        if let sessionID = path.lazy.compactMap(\.sessionID).last {
            browser.openSession(sessionID, inProject: projectID)
            return
        }
        // The compact stack shows the conversation itself: no chat in it means none open.
        if isCompact, browser.openedRemote != nil {
            browser.closeConversation()
        }
        if let projectID {
            browser.openProject(projectID)
        } else if browser.openedProjectID != nil {
            browser.closeProject()
        }
    }

    /// Rebuilds both paths from what the browser has open. A chat already pushed for the open conversation is
    /// kept, even when a fork changed the id its row carries.
    private func syncPathsFromBrowser() {
        let project = browser.openedProjectID.map { [SidebarItem.project($0)] } ?? []
        var stack = project
        if let selected = browser.selectedSessionID {
            if case .session(let pushed)? = stackPath.last, browser.isOpen(pushed) {
                stack.append(.session(pushed))
            } else {
                stack.append(.session(selected))
            }
        }
        if stackPath != stack {
            stackPath = stack
        }
        if sidebarPath != project {
            sidebarPath = project
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

    /// The user-facing reason of an error thrown by the browser.
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
}

extension SidebarItem {
    fileprivate var projectID: String? {
        if case .project(let id) = self { id } else { nil }
    }

    fileprivate var sessionID: String? {
        if case .session(let id) = self { id } else { nil }
    }
}

/// The chat pushed in the compact stack: the browser's open transcript, once it is this conversation. The
/// transcript comes from the browser, never built here, so it survives the view being rebuilt.
private struct OpenConversationView: View {
    let browser: ConversationBrowser
    let sessionID: String

    var body: some View {
        if let transcript = browser.openedRemote, browser.isOpen(sessionID) {
            ChatView(transcript: transcript)
                .id(transcript.sessionID)
        } else {
            ProgressView()
        }
    }
}
