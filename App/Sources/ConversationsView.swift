import HermesAPI
import HermesChat
import SwiftUI

/// Main screen: adaptive navigation.
/// - On compact widths (iPhone): uses a classic, robust single-column NavigationStack.
/// - On regular widths (iPad, Mac): uses a native, professional Two-Column NavigationSplitView.
struct ConversationsView: View {
    let browser: ConversationBrowser
    /// Edited by the settings sheet.
    let appState: AppState

    @State private var isShowingSettings = false
    /// Why the last action on a conversation failed, shown in an alert.
    @State private var failure: String?
    
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
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

    private var iphoneBody: some View {
        NavigationStack {
            ConversationListView(browser: browser, failure: $failure)
                .navigationTitle("Conversations")
                .sidebarToolbar(
                    isShowingSettings: $isShowingSettings,
                    isCreating: browser.isCreating,
                    startConversation: { startConversation(inProject: browser.openedProjectID) }
                )
                // On iPhone, push both Projects (String) and Conversations (SidebarItem) on the stack
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
                        if let session = browser.remoteSessions.sessions.first(where: { $0.id == sessionID }) {
                            ChatView(transcript: browser.remoteSessions.transcript(for: session))
                                .id(sessionID)
                                .onAppear {
                                    browser.openRemote(session)
                                }
                                .onDisappear {
                                    if browser.openedRemote?.sessionID == sessionID {
                                        browser.closeConversation()
                                    }
                                }
                        }
                    }
                }
        }
    }

    private var macPadBody: some View {
        NavigationSplitView {
            NavigationStack {
                ConversationListView(browser: browser, failure: $failure)
                    .navigationTitle("Conversations")
                    .sidebarToolbar(
                        isShowingSettings: $isShowingSettings,
                        isCreating: browser.isCreating,
                        startConversation: { startConversation(inProject: browser.openedProjectID) }
                    )
                    // On Mac/iPad, ONLY push Projects (String) inside the sidebar NavigationStack!
                    // Do NOT declare SidebarItem.self here so it updates the detail pane instead of pushing!
                    .navigationDestination(for: String.self) { projectID in
                        ProjectSidebarView(
                            browser: browser,
                            projectID: projectID,
                            startConversation: { startConversation(inProject: projectID) },
                            failure: $failure
                        )
                    }
            }
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
                            startConversation(inProject: nil)
                        }
                    }
                }
            }
        }
    }

    /// Whether a chat is pushed over the open project. Going back closes the chat, the project stays open.
    /// `nil` while a conversation is being created or the settings are shown: the menu item is disabled.
    /// In the open project (its screen, or the chat of one of its conversations), the conversation is created
    /// there; outside any project otherwise.
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
