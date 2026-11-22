import SwiftUI

extension FocusedValues {
    /// Starts a new conversation in the focused window. `nil` when none can be started there (settings
    /// shown, or a conversation already being created).
    @Entry var newConversation: (@MainActor () -> Void)?
}

/// File ▸ New Conversation, ⌘N. Replaces New Window: the app is used in a single window.
struct NewConversationCommand: Commands {
    @FocusedValue(\.newConversation) private var newConversation

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") {
                newConversation?()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(newConversation == nil)
        }
    }
}
