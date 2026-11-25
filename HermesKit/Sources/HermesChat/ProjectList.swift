import Foundation
import HermesAPI

#if !os(Linux)
    import Observation
#endif

/// The project endpoints of the sidecar. `SidecarClient` conforms; tests provide a fake.
public protocol ProjectStoring: Sendable {
    func listProjects() async throws -> [Project]
    func createProject(name: String) async throws -> Project
    func renameProject(projectID: String, name: String) async throws -> Project
    func deleteProject(projectID: String) async throws
    func attachConversation(conversationID: String, projectID: String) async throws
    func detachConversation(conversationID: String, projectID: String) async throws
}

extension SidecarClient: ProjectStoring {}

/// The projects stored on the sidecar, and which conversations they hold.
///
/// Only built when a sidecar is configured (see `ConnectionSettings.sidecarClient(apiKey:session:)`): without
/// one there is no list, and no project request is made. Changes made here update the list at once, without
/// reloading it. Errors are `ProjectError`.
///
/// `@Observable` is applied on Apple platforms, see `RemoteSessionList` for why it is left out on Linux.
@MainActor
#if !os(Linux)
    @Observable
#endif
public final class ProjectList {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(ProjectError)
    }

    /// The projects in the order the sidecar returns them: by name, ignoring case. A project created or
    /// renamed here takes its place in that order.
    public private(set) var projects: [Project] = []
    public private(set) var state: State = .idle

    private let store: any ProjectStoring

    public init(store: any ProjectStoring) {
        self.store = store
    }

    public var isLoading: Bool {
        state == .loading
    }

    /// The ids of the conversations that are in a project. Empty until the projects are loaded, and after a
    /// failed load: every conversation then counts as in no project.
    public var conversationIDs: Set<String> {
        Set(projects.flatMap(\.conversationIDs))
    }

    /// The project with this id, or `nil`.
    public func project(id: String) -> Project? {
        projects.first { $0.id == id }
    }

    /// The project that holds this conversation, or `nil`.
    public func project(containing conversationID: String) -> Project? {
        projects.first { $0.conversationIDs.contains(conversationID) }
    }

    /// Loads every project and replaces the list. A failure empties it, so that no conversation stays hidden
    /// behind a project the app cannot show. Ignored while a request is running.
    public func reload() async {
        guard !isLoading else { return }
        state = .loading
        do {
            projects = try await store.listProjects()
            state = .loaded
        } catch is CancellationError {
            state = projects.isEmpty ? .idle : .loaded
        } catch {
            projects = []
            state = .failed(ProjectError.from(error))
        }
    }

    /// Creates a project on the sidecar and adds it to the list. Throws `ProjectError`, for example
    /// `nameTaken` or `invalidName`.
    @discardableResult
    public func create(name: String) async throws -> Project {
        let project = try await Self.run { try await store.createProject(name: name) }
        insert(project)
        return project
    }

    /// Renames a project on the sidecar, then moves it to its new place in the list.
    public func rename(_ projectID: String, to name: String) async throws {
        let renamed = try await Self.run { try await store.renameProject(projectID: projectID, name: name) }
        insert(renamed)
    }

    /// Deletes a project on the sidecar and removes it from the list. Its conversations stay on Hermes, in no
    /// project. A project already gone from the sidecar is removed from the list too.
    public func delete(_ projectID: String) async throws {
        do {
            try await Self.run { try await store.deleteProject(projectID: projectID) }
        } catch ProjectError.projectNotFound {
            projects.removeAll { $0.id == projectID }
            throw ProjectError.projectNotFound
        }
        projects.removeAll { $0.id == projectID }
    }

    /// Puts a conversation in a project, taking it out of any other one, as the sidecar does.
    public func attach(_ conversationID: String, to projectID: String) async throws {
        try await Self.run { try await store.attachConversation(conversationID: conversationID, projectID: projectID) }
        projects = projects.map { project in
            var ids = project.conversationIDs.filter { $0 != conversationID }
            if project.id == projectID {
                ids.append(conversationID)
            }
            return ids == project.conversationIDs ? project : project.with(conversationIDs: ids)
        }
    }

    /// Takes a conversation out of a project.
    public func detach(_ conversationID: String, from projectID: String) async throws {
        try await Self.run { try await store.detachConversation(conversationID: conversationID, projectID: projectID) }
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects[index]
        projects[index] = project.with(conversationIDs: project.conversationIDs.filter { $0 != conversationID })
    }

    // MARK: Private

    /// Puts a project at its place in the sidecar order: by name ignoring case, then by id.
    private func insert(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        let index = projects.firstIndex { Self.sortsBefore(project, $0) } ?? projects.endIndex
        projects.insert(project, at: index)
    }

    private static func sortsBefore(_ lhs: Project, _ rhs: Project) -> Bool {
        let left = lhs.name.lowercased()
        let right = rhs.name.lowercased()
        return left != right ? left < right : lhs.id < rhs.id
    }

    /// Runs a store call and maps its failure to `ProjectError`. Cancellation is rethrown as is.
    private static func run<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProjectError.from(error)
        }
    }
}
