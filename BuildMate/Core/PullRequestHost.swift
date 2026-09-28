import Foundation

/// A hosting service that publishes, observes and merges task pull requests.
/// Safety policy (verified heads, bounded retries, exactly-once replies) stays in the orchestrator;
/// hosts only translate it into their own commands and report status in `HostedStatus` form.
protocol PullRequestHost: Sendable {
    func open(task: WorkTask, project: Project, summary: String, base: String, commitSHA: String) async throws -> PullRequest
    func verifiedOpenPR(task: WorkTask, project: Project) async throws -> PullRequest
    func status(task: WorkTask, project: Project) async throws -> HostedStatus
    func retarget(task: WorkTask, project: Project, base: String) async throws
    func ciRun(task: WorkTask, project: Project, runID: String) async throws -> CIRun
    func ciLog(task: WorkTask, project: Project, runID: String) async throws -> String
    func retryCI(task: WorkTask, project: Project, runID: String) async throws
    /// The ID of an already-posted reply carrying `receipt`, so an interrupted post is never duplicated.
    func existingReply(task: WorkTask, project: Project, feedback: ReviewFeedback, receipt: String) async throws -> String?
    /// Posts `body` (already carrying `receipt`) and returns the posted reply's feedback key, for example `comment:123`.
    func postReply(task: WorkTask, project: Project, feedback: ReviewFeedback, body: String) async throws -> String
    func resolve(task: WorkTask, project: Project, threadID: String) async throws
    func merge(task: WorkTask, project: Project, head: String) async throws
    /// Invisible marker appended to replies; must not render in the host's Markdown.
    func receipt(_ token: String) -> String
}

/// A CI run as the orchestrator needs to judge it: only a failed, completed run for the current head may be inspected or retried.
struct CIRun: Sendable {
    var head: String
    var completed: Bool
    var failed: Bool
    var attempt: Int
}

/// Project-level merge preference. `nil` in settings means the repository's own default.
enum MergeStrategy: String, Codable, CaseIterable, Sendable {
    case squash, mergeCommit = "merge_commit", rebase
    var title: String {
        switch self { case .squash: "Squash"; case .mergeCommit: "Merge commit"; case .rebase: "Rebase" }
    }
}

extension Host {
    var supportsPullRequests: Bool { self != .local }
}

extension Project {
    func pullRequestHost(runner: ProcessRunner, root: URL) throws -> any PullRequestHost {
        switch host {
        case .github: GitHub(runner: runner, root: root)
        case .bitbucket: Bitbucket(runner: runner, root: root)
        case .local: throw CoreError.invalid(publicationBlockReason ?? "This repository has no hosting service.")
        }
    }
}

extension ReviewFeedback {
    /// Human review input that needs a recorded response; CI failures and conflicts are repaired instead.
    var needsReply: Bool { ["comment", "thread", "review", "task"].contains(id.split(separator: ":").first.map(String.init) ?? "") }
}
