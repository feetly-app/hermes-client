import HermesChat
import SwiftUI

/// Root view. First launch shows the settings alone. Once configured, a tab bar shows the chat and the settings.
struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        if let browser = appState.browser {
            TabView {
                Tab("Chat", systemImage: "bubble.left.and.bubble.right") {
                    ConversationsView(browser: browser)
                }
                Tab("Settings", systemImage: "gearshape") {
                    SettingsView(appState: appState)
                }
            }
        } else {
            SettingsView(appState: appState)
        }
    }
}
