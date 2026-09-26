import Foundation
import GRDB

/// SQLite owns durable state; the orchestrator is its single logical writer.
final class Store: Sendable {
    let root: URL
    let db: DatabasePool

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Build Mate")) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try DatabasePool(path: root.appending(path: "buildmate.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-core") { db in
            try db.execute(sql: """
            CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT NOT NULL, repoPath TEXT NOT NULL,
              host TEXT NOT NULL, remoteSlug TEXT NOT NULL, defaultBranch TEXT NOT NULL,
              instructions TEXT NOT NULL, settings TEXT NOT NULL, paused BOOLEAN NOT NULL, createdAt DATETIME NOT NULL);
            CREATE TABLE task (id TEXT PRIMARY KEY, projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
              number INTEGER NOT NULL, title TEXT NOT NULL, description TEXT NOT NULL, state TEXT NOT NULL,
              paused BOOLEAN NOT NULL, rank DOUBLE NOT NULL, dependsOn TEXT NOT NULL, stackOn TEXT,
              askBeforeBuild BOOLEAN, origin TEXT NOT NULL, branchName TEXT, worktreePath TEXT,
              workspaceReady BOOLEAN NOT NULL, pr TEXT, retry TEXT,
              createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, doneAt DATETIME,
              UNIQUE(projectId, number));
            CREATE INDEX task_dispatch ON task(state, rank DESC);
            CREATE TABLE session (id TEXT PRIMARY KEY, ownerType TEXT NOT NULL, ownerId TEXT NOT NULL,
              codexThreadId TEXT, status TEXT NOT NULL, currentTurn TEXT, turnCount INTEGER NOT NULL,
              tokensIn INTEGER NOT NULL, tokensOut INTEGER NOT NULL, startedAt DATETIME NOT NULL,
              lastEventAt DATETIME NOT NULL, UNIQUE(ownerType, ownerId));
            CREATE TABLE message (id TEXT PRIMARY KEY, sessionId TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
              role TEXT NOT NULL, kind TEXT NOT NULL, body TEXT NOT NULL, payload TEXT, createdAt DATETIME NOT NULL);
            CREATE TABLE question (id TEXT PRIMARY KEY, taskId TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
              messageId TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE, prompt TEXT NOT NULL,
              options TEXT NOT NULL, allowsFreeText BOOLEAN NOT NULL, blocking BOOLEAN NOT NULL,
              answer TEXT, answeredBy TEXT, answeredAt DATETIME);
            CREATE TABLE approval (id TEXT PRIMARY KEY, taskId TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
              kind TEXT NOT NULL, status TEXT NOT NULL, planText TEXT, createdAt DATETIME NOT NULL, resolvedAt DATETIME);
            CREATE TABLE proof (id TEXT PRIMARY KEY, taskId TEXT NOT NULL UNIQUE REFERENCES task(id) ON DELETE CASCADE,
              recordingPath TEXT, recordingDuration DOUBLE, screenshots TEXT NOT NULL, checks TEXT NOT NULL,
              files INTEGER NOT NULL, additions INTEGER NOT NULL, deletions INTEGER NOT NULL,
              summary TEXT NOT NULL, complete BOOLEAN NOT NULL, producedAt DATETIME NOT NULL);
            CREATE TABLE runAttempt (id TEXT PRIMARY KEY, taskId TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
              attempt INTEGER NOT NULL, phase TEXT NOT NULL, startedAt DATETIME NOT NULL, endedAt DATETIME,
              status TEXT NOT NULL, error TEXT);
            CREATE TABLE attachment (id TEXT PRIMARY KEY, ownerType TEXT NOT NULL, ownerId TEXT NOT NULL,
              kind TEXT NOT NULL, path TEXT NOT NULL, filename TEXT NOT NULL, byteSize INTEGER NOT NULL,
              durationSec DOUBLE, frames TEXT NOT NULL, transcript TEXT);
            CREATE TABLE proposal (id TEXT PRIMARY KEY, projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
              messageId TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE, tasks TEXT NOT NULL,
              shipAs TEXT NOT NULL, status TEXT NOT NULL);
            CREATE TABLE appSettings (id INTEGER PRIMARY KEY CHECK(id = 1), value BLOB NOT NULL);
            """)
        }
        migrator.registerMigration("v2-task-proof") { db in
            try db.execute(sql: "ALTER TABLE task ADD COLUMN proofRequirement TEXT NOT NULL DEFAULT 'automatic'")
            try db.execute(sql: "ALTER TABLE proof ADD COLUMN recordingRequired BOOLEAN NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE proof ADD COLUMN rationale TEXT")
            try db.execute(sql: "UPDATE proof SET recordingRequired = 1 WHERE recordingPath IS NOT NULL")
        }
        migrator.registerMigration("v3-lifecycle-review") { db in
            try db.execute(sql: "ALTER TABLE question ADD COLUMN suggestedAnswer TEXT")
            try db.execute(sql: "ALTER TABLE proof ADD COLUMN commitSHA TEXT")
            try db.execute(sql: "ALTER TABLE proof ADD COLUMN changes TEXT NOT NULL DEFAULT '[]'")
        }
        migrator.registerMigration("v4-project-chat") { db in
            try db.execute(sql: "ALTER TABLE proposal ADD COLUMN createdTaskIds TEXT NOT NULL DEFAULT '[]'")
        }
        migrator.registerMigration("v5-chat-attachments") { db in
            try db.execute(sql: "ALTER TABLE attachment ADD COLUMN removedAt DATETIME")
            try db.execute(sql: "ALTER TABLE attachment ADD COLUMN sourceAttachmentId TEXT")
        }
        try migrator.migrate(db)
        let logs = root.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        if let files = FileManager.default.enumerator(at: logs, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                if values.isRegularFile == true, let modified = values.contentModificationDate, modified < cutoff {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func save<T: Record>(_ value: T) throws { try db.write { try value.save($0) } }
    func all<T: Record>(_ type: T.Type) throws -> [T] { try db.read { try T.fetchAll($0) } }
    func get<T: Record>(_ type: T.Type, _ id: UUID) throws -> T {
        try db.read { db in
            guard let value = try T.fetchOne(db, key: id) else { throw CoreError.invalid("Missing \(T.databaseTableName)") }
            return value
        }
    }
    func settings() throws -> AppSettings {
        try db.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM appSettings WHERE id = 1") else { return AppSettings() }
            return try JSONDecoder().decode(AppSettings.self, from: data)
        }
    }
    func saveSettings(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO appSettings VALUES (1, ?)", arguments: [data]) }
    }
    func createTask(projectId: UUID, title: String, description: String = "", state: TaskState = .backlog,
                    rank: Double = 0, dependsOn: [UUID] = [], proofRequirement: ProofRequirement = .automatic, askBeforeBuild: Bool? = nil) throws -> WorkTask {
        guard [.backlog, .todo].contains(state) else { throw CoreError.invalid("New tasks must be Backlog or Queue") }
        return try db.write { db in
            let number = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(number), 0) + 1 FROM task WHERE projectId = ?", arguments: [projectId])!
            let task = WorkTask(projectId: projectId, number: number, title: title, description: description,
                                state: state, rank: rank, dependsOn: dependsOn, askBeforeBuild: askBeforeBuild, proofRequirement: proofRequirement)
            try task.insert(db)
            return task
        }
    }
    func session(for taskId: UUID, ownerType: String = "task") throws -> Session {
        if let session = try db.read({ try Session.filter(Column("ownerType") == ownerType && Column("ownerId") == taskId).fetchOne($0) }) { return session }
        return try db.write { db in
            if let session = try Session.filter(Column("ownerType") == ownerType && Column("ownerId") == taskId).fetchOne(db) { return session }
            let session = Session(ownerType: ownerType, ownerId: taskId)
            try session.insert(db)
            return session
        }
    }
    func workflow(for project: Project) throws {
        let directory = root.appending(path: "projects/\(project.id)/media")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = String(decoding: try JSONEncoder().encode(project.settings), as: UTF8.self)
        // JSON is valid YAML; no fragile interpolation of shell commands into front matter.
        let text = "---\n\(config)\n---\n\n\(project.instructions)\n"
        try text.write(to: directory.deletingLastPathComponent().appending(path: "WORKFLOW.md"), atomically: true, encoding: .utf8)
    }
}
