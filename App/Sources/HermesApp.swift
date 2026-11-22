import SwiftUI

@main
struct HermesApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // The app is designed for a dark background (the icon and accent colour are tuned for it).
                .preferredColorScheme(.dark)
        }
        .commands {
            NewConversationCommand()
        }
    }
}
