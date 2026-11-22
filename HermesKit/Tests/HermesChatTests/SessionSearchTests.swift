import Foundation
import HermesAPI
import Testing

@testable import HermesChat

@Suite("Conversation search")
struct SessionSearchTests {
    private let sessions: [RemoteSession] = [
        RemoteSession(id: "t", title: "Tuist preview on macOS"),
        RemoteSession(id: "a", title: "Dashboard client Hermès"),
        RemoteSession(id: "b", title: "Price watch", source: "cron"),
        RemoteSession(id: "c"),
    ]

    @Test("the match ignores case", arguments: ["tuist", "TUIST", "TuIsT preview"])
    func ignoresCase(query: String) {
        #expect(sessions.matching(query).map(\.id) == ["t"])
    }

    @Test("the match ignores accents")
    func ignoresAccents() {
        #expect(sessions.matching("hermes").map(\.id) == ["a"])
    }

    @Test("a part of a word matches, untitled sessions by their placeholder, and the order is kept")
    func substringKeepsOrder() {
        #expect(sessions.matching("o").map(\.id) == ["t", "a", "c"])
    }

    @Test("an empty or blank query keeps every session", arguments: ["", "   ", "\n"])
    func blankQuery(query: String) {
        #expect(sessions.matching(query) == sessions)
    }

    @Test("surrounding whitespace is ignored")
    func trimsQuery() {
        #expect(sessions.matching("  price ").map(\.id) == ["b"])
    }

    @Test("no match gives an empty list")
    func noMatch() {
        #expect(sessions.matching("golf").isEmpty)
    }
}
