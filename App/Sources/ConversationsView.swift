import HermesAPI
import HermesChat
import SwiftUI

/// Main screen: adaptive navigation.
/// - On compact widths (iPhone): uses a classic, robust single-column NavigationStack with 100% platform isolation.
/// - On regular widths (iPad, Mac): uses a native Two-Column NavigationSplitView.
///   Column 1: projects list + recent conversations list, navigating to project detail on project tap.
///   Column 2: active conversation detail (ChatView) on conversation tap.
struct ConversationsView: View {
    let browser: ConversationBrowser
    /// Edited by the settings sheet.
    let appState: AppState

    @State private var isShowingSettings = false
    /// Why the last action on a conversation failed, shown in an alert.
    @State private var failure: String?

    // Multi-column split view path for macOS / iPadOS
    @State private var sidebarPath = NavigationPath()

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

    // MARK: - macOS / iPadOS (Two-Column NavigationSplitView)

    private var macPadBody: some View {
        NavigationSplitView {
            NavigationStack(path: $sidebarPath) {
                ConversationListView(
                    browser: browser,
                    failure: $failure,
                    onSelectSession: { session in
                        browser.openRemote(session)
                    }
                )
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
                        failure: $failure,
                        onSelectSession: { session in
                            browser.openRemote(session, inProject: projectID)
                        }
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
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
        .task(id: ObjectIdentifier(browser)) {
            await browser.reloadSessions()
        }
        .refreshable {
            await browser.reloadSessions()
        }
        .onAppear {
            if let projectID = browser.openedProjectID, sidebarPath.isEmpty {
                sidebarPath.append(projectID)
            }
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
