import Foundation
import CryptoKit

/// GitHub through the `gh` CLI. Review/CI policy lives in HostedReview.swift.
struct GitHub: PullRequestHost {
    let runner: ProcessRunner
    let root: URL

    func open(task: WorkTask, project: Project, summary: String, base: String, commitSHA: String) async throws -> PullRequest {
        guard project.host == .github else { throw CoreError.invalid(project.publicationBlockReason ?? "GitHub repository required.") }
        guard let branch = task.branchName, let cwd = task.worktreePath else { throw CoreError.invalid("Missing branch") }
        var existingPR: PullRequest?
        if task.pr != nil {
            existingPR = try await verifiedOpenPR(task: task, project: project)
        } else {
            // Recover an already-created PR after an interrupted response without duplicating it.
            let existing = try await runner.run("gh", ["pr", "list", "--repo", project.remoteSlug, "--head", branch, "--state", "open", "--json", "number,url,baseRefName"], cwd: cwd)
            let values = try JSONDecoder().decode(JSON.self, from: Data(existing.output.utf8)).array
            if let value = values.first, let number = value["number"].int, let url = value["url"].string {
                existingPR = PullRequest(number: number, url: url, baseBranch: value["baseRefName"].string ?? base)
            }
        }
        let body = try Self.changeDescription(summary)
        // Publish exactly the reviewed object, even if an editor moves the branch during publication.
        try await runner.pushReviewed(commitSHA, branch: branch, cwd: cwd)
        let file = root.appending(path: "projects/\(project.id)/pr-\(task.id).md")
        try body.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        if let existingPR {
            _ = try await runner.run("gh", ["pr", "edit", String(existingPR.number), "--repo", project.remoteSlug, "--title", task.title, "--body-file", file.path, "--base", base], cwd: cwd)
            return PullRequest(number: existingPR.number, url: existingPR.url, baseBranch: base)
        }
        let result = try await runner.run("gh", ["pr", "create", "--repo", project.remoteSlug, "--base", base, "--head", branch, "--title", task.title, "--body-file", file.path], cwd: cwd)
        let url = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = try await runner.run("gh", ["pr", "view", url, "--repo", project.remoteSlug, "--json", "number,url,baseRefName"], cwd: cwd)
        let value = try JSONDecoder().decode(JSON.self, from: Data(detail.output.utf8))
        guard let number = value["number"].int, let canonical = value["url"].string else { throw CoreError.invalid("Invalid GitHub PR response") }
        return PullRequest(number: number, url: canonical, baseBranch: value["baseRefName"].string ?? base)
    }

    func verifiedOpenPR(task: WorkTask, project: Project) async throws -> PullRequest {
        guard project.host == .github, let pr = task.pr, let branch = task.branchName else { throw CoreError.invalid("The task has no supported pull request.") }
        let result = try await runner.run("gh", ["pr", "view", String(pr.number), "--repo", project.remoteSlug, "--json", "state,headRefName,baseRefName"], cwd: task.worktreePath)
        let value = try JSONDecoder().decode(JSON.self, from: Data(result.output.utf8))
        guard value["state"].string == "OPEN" else { throw CoreError.invalid("This pull request is no longer open. Create a new task for further changes.") }
        guard value["headRefName"].string == branch else { throw CoreError.invalid("The pull request branch no longer matches this task's worktree.") }
        return PullRequest(number: pr.number, url: pr.url, baseBranch: value["baseRefName"].string ?? pr.baseBranch)
    }

    /// A PR contains only the change description, never the full review-evidence report.
    static func changeDescription(_ summary: String) throws -> String {
        var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Durable older threads may have encoded the report more than once.
        for _ in 0..<5 {
            if text.hasPrefix("```json\n"), text.hasSuffix("```") {
                text = String(text.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else { break }
            guard let report = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) else {
                if text.hasPrefix("{") { break } // Do not publish a malformed JSON report either.
                return text
            }
            switch report {
            case .object(let fields):
                guard let changes = fields["changes"] ?? fields["summary"] else {
                    throw CoreError.invalid("The review report has no change description. Ask the agent for a short Markdown summary before opening the pull request.")
                }
                text = changes.string ?? changes.text
            case .array(let changes):
                let bullets = changes.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !bullets.isEmpty, bullets.count == changes.count, bullets.allSatisfy({ !$0.isEmpty }) else { break }
                return bullets.map { "- " + $0.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n")
            case .string(let description): text = description
            default: break
            }
        }
        throw CoreError.invalid("The review summary is not a usable change description. Ask the agent for a short Markdown summary before opening the pull request.")
    }

    static func fingerprint(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func fingerprint(_ value: JSON) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return fingerprint(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))
    }
    func readJSON(_ args: [String], cwd: String? = nil) async throws -> JSON {
        let output = try await runner.run("gh", args, cwd: cwd).output
        let value = try JSONDecoder().decode(JSON.self, from: Data(output.utf8))
        guard value["errors"].array.isEmpty else { throw CoreError.invalid("GitHub could not complete the requested operation.") }
        return value
    }
    func status(task: WorkTask, project: Project) async throws -> HostedStatus {
        guard let pr = task.pr, project.host == .github else { throw CoreError.invalid("GitHub PR required") }
        let value = try await readJSON(["pr", "view", String(pr.number), "--repo", project.remoteSlug, "--json", "state,headRefOid,headRefName,baseRefName,mergeStateStatus,reviewDecision,isDraft,statusCheckRollup"], cwd: task.worktreePath)
        guard let state = value["state"].string, let head = value["headRefOid"].string else { throw CoreError.invalid("Incomplete GitHub status; merge is withheld.") }
        var feedback: [ReviewFeedback] = []
        if state == "OPEN" {
            let comments = try await readJSON(["api", "repos/\(project.remoteSlug)/issues/\(pr.number)/comments?per_page=100", "--paginate", "--slurp"])
            for comment in comments.array.flatMap(\.array) {
                guard let id = comment["id"].int, let body = comment["body"].string, !body.isEmpty else { continue }
                feedback.append(ReviewFeedback(id: "comment:\(id):" + Self.fingerprint(body), body: body))
            }
            let reviews = try await readJSON(["api", "repos/\(project.remoteSlug)/pulls/\(pr.number)/reviews?per_page=100", "--paginate", "--slurp"])
            var latest: [String: JSON] = [:]
            for review in reviews.array.flatMap(\.array) where ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(review["state"].string ?? "") { latest[review["user"]["login"].string ?? ""] = review }
            for review in latest.values where review["state"].string == "CHANGES_REQUESTED" {
                guard let id = review["id"].int else { continue }
                let body = review["body"].string ?? ""
                feedback.append(ReviewFeedback(id: "review:\(id):" + Self.fingerprint(body), body: "Reviewer requested changes. " + body))
            }
            let slug = project.remoteSlug.split(separator: "/")
            guard slug.count == 2 else { throw CoreError.invalid("Invalid GitHub repository") }
            let query = "query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){nodes{id isResolved isOutdated comments(last:100){nodes{id databaseId body updatedAt author{login} commit{oid}} pageInfo{hasPreviousPage}}} pageInfo{hasNextPage endCursor}}}}}"
            let pages = try await readJSON(["api", "graphql", "--paginate", "--slurp", "-f", "query=" + query, "-f", "owner=" + slug[0], "-f", "name=" + slug[1], "-F", "number=\(pr.number)"])
            for page in pages.array {
                guard page["errors"] == .null, page["data"]["repository"]["pullRequest"] != .null else { throw CoreError.invalid("Review threads could not be read completely.") }
                for thread in page["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"].array where thread["isResolved"].bool == false {
                    guard thread["comments"]["pageInfo"]["hasPreviousPage"].bool != true else { throw CoreError.invalid("A review thread exceeds the inspection limit. Review this conversation manually before merging.") }
                    let comments = thread["comments"]["nodes"].array
                    guard let firstID = comments.first?["databaseId"].int else { continue }
                    for comment in comments {
                        guard let id = comment["databaseId"].int, let body = comment["body"].string else { continue }
                        feedback.append(ReviewFeedback(id: "thread:\(id):" + Self.fingerprint(body), body: (thread["isOutdated"].bool == true ? "Comment on an older diff; verify whether it still applies.\n" : "") + body, commentID: firstID, threadID: thread["id"].string))
                    }
                }
            }
        }
        var checks = value["statusCheckRollup"].array
        for index in checks.indices where ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE"].contains(checks[index]["conclusion"].string ?? "") {
            guard let raw = checks[index]["detailsUrl"].string, let url = URL(string: raw), url.host == "github.com",
                  url.path.hasPrefix("/" + project.remoteSlug + "/actions/runs/"),
                  let runID = url.path.split(separator: "/").dropFirst(4).first, runID.allSatisfy(\.isNumber) else { continue }
            let run = try await readJSON(["run", "view", String(runID), "--repo", project.remoteSlug, "--json", "headSha,status,conclusion,attempt"], cwd: task.worktreePath)
            guard run["headSha"].string == head else { throw CoreError.invalid("CI information refers to an older head. Waiting for GitHub to refresh it.") }
            if case .object(var fields) = checks[index] {
                fields["runId"] = .string(String(runID)); fields["attempt"] = run["attempt"]
                // A rerun may already be pending while the check rollup still reports its previous failure.
                if run["status"].string != "completed" { fields["conclusion"] = .null; fields["status"] = .string("IN_PROGRESS") }
                checks[index] = .object(fields)
            }
        }
        return HostedStatus(state: state, head: head, branch: value["headRefName"].string ?? "", base: value["baseRefName"].string ?? "", mergeState: value["mergeStateStatus"].string ?? "UNKNOWN", reviewDecision: value["reviewDecision"].string ?? "", draft: value["isDraft"].bool ?? true, feedback: feedback, checks: checks)
    }
    func retarget(task: WorkTask, project: Project, base: String) async throws {
        guard let pr = task.pr else { throw CoreError.invalid("The task has no pull request.") }
        _ = try await runner.run("gh", ["pr", "edit", String(pr.number), "--repo", project.remoteSlug, "--base", base], cwd: task.worktreePath)
    }
    func ciRun(task: WorkTask, project: Project, runID: String) async throws -> CIRun {
        guard runID.allSatisfy(\.isNumber), !runID.isEmpty else { throw CoreError.invalid("A numeric GitHub Actions run ID is required.") }
        let run = try await readJSON(["run", "view", runID, "--repo", project.remoteSlug, "--json", "headSha,status,conclusion,attempt"])
        return CIRun(head: run["headSha"].string ?? "", completed: run["status"].string == "completed",
                     failed: ["failure", "timed_out", "startup_failure"].contains(run["conclusion"].string ?? ""), attempt: run["attempt"].int ?? 1)
    }
    func ciLog(task: WorkTask, project: Project, runID: String) async throws -> String {
        try await runner.run("gh", ["run", "view", runID, "--repo", project.remoteSlug, "--log-failed"], cwd: task.worktreePath).output
    }
    func retryCI(task: WorkTask, project: Project, runID: String) async throws {
        _ = try await runner.run("gh", ["run", "rerun", runID, "--repo", project.remoteSlug, "--failed"], cwd: task.worktreePath)
    }
    func receipt(_ token: String) -> String { "<!-- review-response:\(token) -->" }
    func existingReply(task: WorkTask, project: Project, feedback: ReviewFeedback, receipt: String) async throws -> String? {
        guard let pr = task.pr else { return nil }
        let collection = feedback.commentID == nil ? "repos/\(project.remoteSlug)/issues/\(pr.number)/comments?per_page=100" : "repos/\(project.remoteSlug)/pulls/\(pr.number)/comments?per_page=100"
        let match = try await readJSON(["api", collection, "--paginate", "--slurp"]).array.flatMap(\.array).first { $0["body"].string?.contains(receipt) == true }
        return match?["id"].int.map { "\(feedback.commentID == nil ? "comment" : "thread"):\($0)" }
    }
    func postReply(task: WorkTask, project: Project, feedback: ReviewFeedback, body: String) async throws -> String {
        guard let pr = task.pr else { throw CoreError.invalid("The task has no pull request.") }
        let endpoint = feedback.commentID.map { "repos/\(project.remoteSlug)/pulls/\(pr.number)/comments/\($0)/replies" } ?? "repos/\(project.remoteSlug)/issues/\(pr.number)/comments"
        let file = root.appending(path: "review-reply-\(task.id).json")
        try JSON.object(["body": .string(body)]).text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let posted = try await readJSON(["api", endpoint, "--method", "POST", "--input", file.path])
        guard let id = posted["id"].int else { throw CoreError.invalid("GitHub did not confirm the review reply. It will be reconciled before retrying.") }
        return "\(feedback.commentID == nil ? "comment" : "thread"):\(id)"
    }
    func resolve(task: WorkTask, project: Project, threadID: String) async throws {
        _ = try await readJSON(["api", "graphql", "-f", "query=mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}", "-f", "id=" + threadID])
    }
    func merge(task: WorkTask, project: Project, head: String) async throws {
        let methods = try await readJSON(["repo", "view", project.remoteSlug, "--json", "squashMergeAllowed,rebaseMergeAllowed,mergeCommitAllowed"])
        let allowed: [MergeStrategy: Bool] = [.squash: methods["squashMergeAllowed"].bool == true, .mergeCommit: methods["mergeCommitAllowed"].bool == true, .rebase: methods["rebaseMergeAllowed"].bool == true]
        let strategy: MergeStrategy?
        if let preferred = project.settings.mergeStrategy {
            guard allowed[preferred] == true else { throw CoreError.invalid("This repository doesn’t allow \(preferred.title.lowercased()) merges. Choose another merge method in Settings.") }
            strategy = preferred
        } else { strategy = [MergeStrategy.squash, .mergeCommit, .rebase].first { allowed[$0] == true } }
        guard let strategy, let pr = task.pr else { throw CoreError.invalid("No supported merge method is enabled for this repository.") }
        let flag = switch strategy { case .squash: "--squash"; case .mergeCommit: "--merge"; case .rebase: "--rebase" }
        // GitHub enforces branch rules and merge queues; never bypass with --admin.
        _ = try await runner.run("gh", ["pr", "merge", String(pr.number), "--repo", project.remoteSlug, flag, "--auto", "--match-head-commit", head], cwd: task.worktreePath)
    }
}
