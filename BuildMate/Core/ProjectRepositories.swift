import Foundation
import GRDB

struct ProjectRepository: Record {
    static let databaseTableName = "projectRepository"
    var id = UUID()
    var projectId: UUID
    var name: String
    var repoPath: String
    var host: Host
    var remoteSlug: String
    var defaultBranch: String
    var removed = false

    /// Keep shared instructions/settings, but route Git and hosting operations to this repository.
    func applying(to project: Project) -> Project {
        var result = project
        result.repoPath = repoPath; result.host = host; result.remoteSlug = remoteSlug; result.defaultBranch = defaultBranch
        return result
    }
}

extension Store {
    // Discovery still produces a Project. Register its initial repository in the same transaction.
    // The original metadata columns are retained for compatibility; task routing uses repository IDs.
    func save(_ project: Project) throws {
        try db.write { db in
            let previous = try Project.fetchOne(db, key: project.id)
            if previous == nil, try ProjectRepository.filter(Column("repoPath") == project.repoPath && Column("removed") == false).fetchCount(db) > 0 {
                throw CoreError.invalid("This repository already belongs to another project.")
            }
            try project.save(db)
            if previous == nil {
                try ProjectRepository(id: project.id, projectId: project.id, name: project.name, repoPath: project.repoPath,
                    host: project.host, remoteSlug: project.remoteSlug, defaultBranch: project.defaultBranch).insert(db)
            } else if previous?.repoPath != project.repoPath || previous?.host != project.host || previous?.remoteSlug != project.remoteSlug || previous?.defaultBranch != project.defaultBranch {
                // Preserve the link's removal state when legacy import code refreshes metadata.
                if var repository = try ProjectRepository.fetchOne(db, key: project.id) {
                    repository.repoPath = project.repoPath; repository.host = project.host
                    repository.remoteSlug = project.remoteSlug; repository.defaultBranch = project.defaultBranch
                    try repository.save(db)
                }
            }
        }
    }

    func repositories(_ projectID: UUID, includingRemoved: Bool = false) throws -> [ProjectRepository] {
        try db.read { db in
            try ProjectRepository.filter(Column("projectId") == projectID).order(Column("name"), Column("id")).fetchAll(db)
                .filter { includingRemoved || !$0.removed }
                .sorted { if ($0.id == projectID) != ($1.id == projectID) { return $0.id == projectID }; return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    static func taskRepository(_ db: Database, projectID: UUID, requested: UUID?) throws -> ProjectRepository {
        let available = try ProjectRepository.filter(Column("projectId") == projectID && Column("removed") == false).fetchAll(db)
        if let requested, let match = available.first(where: { $0.id == requested }) { return match }
        guard requested == nil, available.count == 1, let only = available.first else {
            throw CoreError.invalid(available.isEmpty ? "Add a repository in Project Settings before creating work." : "Choose a repository for this task.")
        }
        return only
    }

    func project(for task: WorkTask) throws -> Project {
        let project = try get(Project.self, task.projectId)
        let repository = try get(ProjectRepository.self, task.repositoryID ?? task.projectId)
        guard repository.projectId == task.projectId else { throw CoreError.invalid("Task repository belongs to another project.") }
        return repository.applying(to: project)
    }
}

extension Orchestrator {
    func addRepository(projectID: UUID, path: String) async throws {
        let discovery = try await ProjectDiscovery(runner: runner).inspect(path: path)
        let source = discovery.project
        guard discovery.authenticated || source.host == .local || source.host == .bitbucket else { throw CoreError.invalid(discovery.status + ". " + (discovery.setupCommand ?? "")) }
        try Task.checkCancellation()
        try await store.db.write { db in
            guard try Project.fetchOne(db, key: projectID) != nil else { throw CoreError.invalid("Project no longer exists.") }
            let allLinks = try ProjectRepository.fetchAll(db)
            guard !allLinks.contains(where: { !$0.removed && $0.projectId != projectID && $0.repoPath == source.repoPath }) else {
                throw CoreError.invalid("This repository already belongs to another project.")
            }
            let links = allLinks.filter { $0.projectId == projectID }
            if var existing = links.first(where: { $0.repoPath == source.repoPath }) {
                guard existing.removed else { return }
                existing.removed = false; try existing.save(db)
            } else {
                try ProjectRepository(projectId: projectID, name: source.name, repoPath: source.repoPath, host: source.host,
                    remoteSlug: source.remoteSlug, defaultBranch: source.defaultBranch).insert(db)
            }
        }
    }

    func removeRepository(_ repositoryID: UUID) async throws {
        let repository = try store.get(ProjectRepository.self, repositoryID)
        // Keep old tasks and their host identity; unlinking is not file deletion.
        try await store.db.write { db in
            let tasks = try WorkTask.filter(Column("projectId") == repository.projectId).fetchAll(db)
            guard !tasks.contains(where: { ($0.repositoryID ?? $0.projectId) == repositoryID && (!$0.state.terminal || $0.worktreePath != nil) }) else {
                throw CoreError.invalid("Finish or delete this repository’s unfinished tasks before removing it.")
            }
            guard var current = try ProjectRepository.fetchOne(db, key: repositoryID) else { throw CoreError.invalid("Repository no longer exists.") }
            current.removed = true; try current.save(db)
        }
        // A running chat must not continue using a removed checkout or stale repository list.
        await stopProjectChat(repository.projectId)
    }
}
