import Foundation
import HermesAPI
import Testing

@testable import HermesChat

@Suite("Sidebar row content")
struct SessionKindTests {
    @Test("a cron session is a scheduled entry with its own title")
    func cronSession() {
        let session = RemoteSession(id: "c", title: "Price watch", source: "cron")

        #expect(session.kind == .scheduled)
        #expect(session.displayTitle == "Price watch")
    }

    @Test("sessions from other sources, or without a source, are chats", arguments: [
        "api_server", "local", "tui", "telegram", nil,
    ])
    func otherSources(source: String?) {
        #expect(RemoteSession(id: "r", source: source).kind == .chat)
    }

    @Test("a session without a title gets the placeholder")
    func untitled() {
        #expect(RemoteSession(id: "r").displayTitle == ConversationTitle.placeholder)
    }
}
