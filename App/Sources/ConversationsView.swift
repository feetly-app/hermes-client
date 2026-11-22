import HermesAPI
import HermesChat
import SwiftUI

/// Main screen: a split view with the conversation list and the open conversation.
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
            ConversationListView(browser: browser, failure: $failure)
                .navigationTitle("Conversations")
                .toolbar {
                    ToolbarItem(placement: .leadingAction) {
                        Button("Settings", systemImage: "gearshape") {
                            isShowingSettings = true
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("New conversation", systemImage: "square.and.pencil", action: startConversation)
                            .disabled(browser.isCreating)
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
                        Button("New conversation", action: startConversation)
                    }
                }
            }
        }
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
    }

    private func startConversation() {
        Task {
            do {
                try await browser.createConversation()
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
