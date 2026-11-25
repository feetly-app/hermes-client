import Foundation
import HermesAPI
import Testing

@testable import HermesChat

@MainActor
@Suite("Project list")
struct ProjectListTests {
    private static let hermes = Project(id: "p-hermes", name: "Hermes", conversationIDs: ["s1", "s2"])
    private static let notes = Project(id: "p-notes", name: "notes", conversationIDs: ["s3"])

    @Test("starts idle and empty, then loads the projects in the sidecar order")
    func reload() async {
        let store = FakeProjectStore(projects: [Self.hermes, Self.notes])
        let list = ProjectList(store: store)
        #expect(list.state == .idle)
        #expect(list.projects.isEmpty)
        #expect(list.conversationIDs.isEmpty)

        await list.reload()

        #expect(list.state == .loaded)
        #expect(list.projects.map(\.id) == ["p-hermes", "p-notes"])
        #expect(list.conversationIDs == ["s1", "s2", "s3"])
        #expect(list.project(containing: "s3")?.id == "p-notes")
        #expect(list.project(containing: "s9") == nil)
        #expect(list.project(id: "p-hermes") == Self.hermes)
    }

    @Test("a failed load reports the error and empties the list, so that no conversation stays hidden")
    func failedReload() async {
        let store = FakeProjectStore(projects: [Self.hermes])
        let list = ProjectList(store: store)
        await list.reload()
        #expect(!list.conversationIDs.isEmpty)

        await store.fail("list", with: .api(.network))
        await list.reload()

        #expect(list.state == .failed(.api(.network)))
        #expect(list.projects.isEmpty)
        #expect(list.conversationIDs.isEmpty)
    }

    @Test("a created project takes its place by name, ignoring case")
    func create() async throws {
        let store = FakeProjectStore(projects: [Self.hermes, Self.notes])
        let list = ProjectList(store: store)
        await list.reload()

        let created = try await list.create(name: "Inbox")

        #expect(created.name == "Inbox")
        #expect(list.projects.map(\.name) == ["Hermes", "Inbox", "notes"])
        #expect(await store.calls.last == .create("Inbox"))
    }

    @Test("a refused name throws its typed error and leaves the list as it was")
    func createRefused() async throws {
        let store = FakeProjectStore(projects: [Self.hermes])
        let list = ProjectList(store: store)
        await list.reload()

        await store.fail("create", with: .nameTaken)
        await #expect(throws: ProjectError.nameTaken) { try await list.create(name: "hermes") }
        await store.fail("create", with: .invalidName("the name must not be empty"))
        await #expect(throws: ProjectError.invalidName("the name must not be empty")) {
            try await list.create(name: " ")
        }

        #expect(list.projects == [Self.hermes])
    }

    @Test("a renamed project moves to its new place and keeps its conversations")
    func rename() async throws {
        let store = FakeProjectStore(projects: [Self.hermes, Self.notes])
        let list = ProjectList(store: store)
        await list.reload()

        try await list.rename("p-hermes", to: "Zeta")

        #expect(list.projects.map(\.name) == ["notes", "Zeta"])
        #expect(list.project(id: "p-hermes")?.conversationIDs == ["s1", "s2"])
    }

    @Test("a deleted project leaves the list, and its conversations are in no project")
    func delete() async throws {
        let store = FakeProjectStore(projects: [Self.hermes, Self.notes])
        let list = ProjectList(store: store)
        await list.reload()

        try await list.delete("p-hermes")

        #expect(list.projects.map(\.id) == ["p-notes"])
        #expect(list.conversationIDs == ["s3"])
        #expect(await store.calls.last == .delete("p-hermes"))
    }

    @Test("a project already deleted elsewhere is removed from the list, and the error is reported")
    func deleteGone() async throws {
        let store = FakeProjectStore(projects: [Self.hermes])
        let list = ProjectList(store: store)
        await list.reload()
        await store.fail("delete", with: .projectNotFound)

        await #expect(throws: ProjectError.projectNotFound) { try await list.delete("p-hermes") }

        #expect(list.projects.isEmpty)
    }

    @Test("a failed delete keeps the project")
    func deleteFailed() async throws {
        let store = FakeProjectStore(projects: [Self.hermes])
        let list = ProjectList(store: store)
        await list.reload()
        await store.fail("delete", with: .api(.network))

        await #expect(throws: ProjectError.api(.network)) { try await list.delete("p-hermes") }

        #expect(list.projects == [Self.hermes])
    }

    @Test("attaching moves a conversation out of its project into another one")
    func attach() async throws {
        let store = FakeProjectStore(projects: [Self.hermes, Self.notes])
        let list = ProjectList(store: store)
        await list.reload()

        try await list.attach("s1", to: "p-notes")
        try await list.attach("s9", to: "p-notes")

        #expect(list.project(id: "p-hermes")?.conversationIDs == ["s2"])
        #expect(list.project(id: "p-notes")?.conversationIDs == ["s3", "s1", "s9"])
        #expect(await store.calls.suffix(2) == [
            .attach(conversation: "s1", project: "p-notes"), .attach(conversation: "s9", project: "p-notes"),
        ])
    }

    @Test("detaching takes a conversation out of its project; a failure changes nothing")
    func detach() async throws {
        let store = FakeProjectStore(projects: [Self.hermes])
        let list = ProjectList(store: store)
        await list.reload()

        try await list.detach("s1", from: "p-hermes")
        #expect(list.project(id: "p-hermes")?.conversationIDs == ["s2"])

        await store.fail("detach", with: .api(.timeout))
        await #expect(throws: ProjectError.api(.timeout)) { try await list.detach("s2", from: "p-hermes") }
        #expect(list.project(id: "p-hermes")?.conversationIDs == ["s2"])
    }

    @Test("store errors that are not project errors are mapped to api errors")
    func mapsForeignErrors() async {
        let list = ProjectList(store: FailingStore())
        await list.reload()
        #expect(list.state == .failed(.api(.timeout)))
    }
}

/// A store whose listing fails with a raw `HermesAPIError`.
private struct FailingStore: ProjectStoring {
    func listProjects() async throws -> [Project] { throw HermesAPIError.timeout }
    func createProject(name: String) async throws -> Project { throw HermesAPIError.timeout }
    func renameProject(projectID: String, name: String) async throws -> Project { throw HermesAPIError.timeout }
    func deleteProject(projectID: String) async throws { throw HermesAPIError.timeout }
    func attachConversation(conversationID: String, projectID: String) async throws { throw HermesAPIError.timeout }
    func detachConversation(conversationID: String, projectID: String) async throws { throw HermesAPIError.timeout }
}

@Suite("Sidecar client from the settings")
struct SidecarClientSettingsTests {
    @Test("without a sidecar, there is no sidecar client, so no project request can be made")
    func noSidecar() {
        let settings = ConnectionSettings(baseURLString: "https://hermes.example.test")
        #expect(settings.sidecarClient(apiKey: "key") == nil)
        let blank = ConnectionSettings(baseURLString: "https://hermes.example.test", sidecarURLString: "  ")
        #expect(blank.sidecarClient(apiKey: "key") == nil)
    }

    @Test("with a sidecar path, the client points at it with the instance key")
    func withSidecar() {
        let settings = ConnectionSettings(baseURLString: "https://hermes.example.test", sidecarURLString: "/sidecar")
        let client = settings.sidecarClient(apiKey: "key")
        #expect(client?.configuration.baseURL.absoluteString == "https://hermes.example.test/sidecar")
        #expect(client?.configuration.apiKey == "key")
    }
}
