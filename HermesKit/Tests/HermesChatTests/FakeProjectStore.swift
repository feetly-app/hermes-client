import Foundation
import HermesAPI

@testable import HermesChat

/// A sidecar that keeps its projects in memory, sorted by name as the sidecar does. Records the calls it
/// receives; each call can be made to fail.
actor FakeProjectStore: ProjectStoring {
    enum Call: Equatable {
        case list
        case create(String)
        case rename(String, String)
        case delete(String)
        case attach(conversation: String, project: String)
        case detach(conversation: String, project: String)
        case attachRepository(url: String, project: String)
        case detachRepository(repository: String, project: String)
    }

    private(set) var projects: [Project]
    private(set) var calls: [Call] = []
    private var failures: [String: ProjectError] = [:]
    private var nextID = 1

    init(projects: [Project] = []) {
        self.projects = projects
    }

    /// Makes every later call of this kind (`list`, `create`, `rename`, `delete`, `attach`, `detach`) fail.
    func fail(_ kind: String, with error: ProjectError?) {
        failures[kind] = error
    }

    func listProjects() async throws -> [Project] {
        calls.append(.list)
        try check("list")
        return projects
    }

    func createProject(name: String) async throws -> Project {
        calls.append(.create(name))
        try check("create")
        let project = Project(id: "project-\(nextID)", name: name)
        nextID += 1
        projects.append(project)
        return project
    }

    func renameProject(projectID: String, name: String) async throws -> Project {
        calls.append(.rename(projectID, name))
        try check("rename")
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw ProjectError.projectNotFound }
        projects[index] = projects[index].with(name: name)
        return projects[index]
    }

    func deleteProject(projectID: String) async throws {
        calls.append(.delete(projectID))
        try check("delete")
        guard projects.contains(where: { $0.id == projectID }) else { throw ProjectError.projectNotFound }
        projects.removeAll { $0.id == projectID }
    }

    func attachConversation(conversationID: String, projectID: String) async throws {
        calls.append(.attach(conversation: conversationID, project: projectID))
        try check("attach")
        guard projects.contains(where: { $0.id == projectID }) else { throw ProjectError.projectNotFound }
        projects = projects.map { project in
            var ids = project.conversationIDs.filter { $0 != conversationID }
            if project.id == projectID {
                ids.append(conversationID)
            }
            return project.with(conversationIDs: ids)
        }
    }

    func detachConversation(conversationID: String, projectID: String) async throws {
        calls.append(.detach(conversation: conversationID, project: projectID))
        try check("detach")
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw ProjectError.projectNotFound }
        projects[index] = projects[index].with(conversationIDs: projects[index].conversationIDs.filter { $0 != conversationID })
    }

    func attachRepository(url: String, projectID: String) async throws -> ProjectRepository {
        calls.append(.attachRepository(url: url, project: projectID))
        try check("attachRepository")
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw ProjectError.projectNotFound }
        let name = url.components(separatedBy: "/").suffix(2).joined(separator: "/")
        let repo = ProjectRepository(id: "repo-\(nextID)", name: name, url: url)
        nextID += 1
        var repos = projects[index].repositories
        repos.append(repo)
        projects[index] = Project(id: projects[index].id, name: projects[index].name, repositories: repos, conversationIDs: projects[index].conversationIDs)
        return repo
    }

    func detachRepository(repositoryID: String, projectID: String) async throws {
        calls.append(.detachRepository(repository: repositoryID, project: projectID))
        try check("detachRepository")
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw ProjectError.projectNotFound }
        var repos = projects[index].repositories
        guard repos.contains(where: { $0.id == repositoryID }) else { throw ProjectError.repositoryNotFound }
        repos.removeAll { $0.id == repositoryID }
        projects[index] = Project(id: projects[index].id, name: projects[index].name, repositories: repos, conversationIDs: projects[index].conversationIDs)
    }

    private func check(_ kind: String) throws {
        if let error = failures[kind] {
            throw error
        }
    }
}
