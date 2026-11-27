import HermesChat
import SwiftUI

/// Root view. First launch shows the settings alone. Once configured, the conversations, with the settings
/// one button away in the conversation list's toolbar.
struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        if let browser = appState.browser {
            ConversationsView(browser: browser, appState: appState)
        } else {
            SettingsView(appState: appState)
        }
    }
}
