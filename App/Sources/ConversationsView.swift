import HermesAPI
import HermesChat
import SwiftUI

/// Main screen: a split view with the sidebar (projects and conversations) and the open conversation or project.
/// A new conversation is a session created on the instance, on the model set in the connection settings.
/// On compact widths the split view collapses into a navigation stack.
struct ConversationsView: View {
    let browser: ConversationBrowser
    /// Edited by the settings sheet.
    let appState: AppState

    @State private var isShowingSettings = false
    /// Why the last action on a conversation failed, shown in an alert.
    @State private var failure: String?

    var body: some View {
        NavigationSplitView {
            Group {
                if let projectID = browser.openedProjectID {
                    ProjectSidebarView(
                        browser: browser,
                        projectID: projectID,
                        startConversation: { startConversation(inProject: projectID) },
                        failure: $failure
                    )
                } else {
                    ConversationListView(browser: browser, failure: $failure)
                        .navigationTitle("Conversations")
                }
            }
            .animation(.default, value: browser.openedProjectID)
            .toolbar {
                if browser.openedProjectID == nil {
                    ToolbarItem(placement: .leadingAction) {
                        Button("Settings", systemImage: "gearshape") {
                            isShowingSettings = true
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        // Always outside any project: a conversation in a project starts from its screen.
                        Button("New conversation", systemImage: "square.and.pencil") {
                            startConversation(inProject: nil)
                        }
                        .disabled(browser.isCreating)
                    }
                }
            }
        } detail: {
            Group {
                if let transcript = browser.openedRemote {
                    ChatView(transcript: transcript)
                        // A new view per session: its draft and scroll position belong to one conversation.
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
