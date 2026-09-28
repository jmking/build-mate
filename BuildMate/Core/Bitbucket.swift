import Foundation

/// Bitbucket Cloud through the TWG CLI (`twg bitbucket …`). Review/CI policy lives in HostedReview.swift.
/// TWG owns Bitbucket credentials; Git pushes use the clone's own credentials.
struct Bitbucket: PullRequestHost {
    let runner: ProcessRunner
    let root: URL
    /// Comment and task reads fail closed at this bound rather than silently missing feedback.
    static let readLimit = 1000
    /// Replies carry a Markdown link-reference receipt: Bitbucket renders HTML comments as visible text.
    static let receiptPrefix = "[//]: # (review-response:"

    static func slug(_ remoteSlug: String) throws -> (workspace: String, repo: String) {
        let parts = remoteSlug.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw CoreError.invalid("Invalid Bitbucket repository") }
        return (parts[0], parts[1])
    }

    /// Runs a TWG Bitbucket command as a script: JSON on stdout, failures reported as `{"ok": false, "error": …}`.
    static func run(_ runner: ProcessRunner, _ args: [String], remoteSlug: String, cwd: String?, timeout: Double = 60) async throws -> JSON {
        let (workspace, repo) = try slug(remoteSlug)
        let result = try await runner.run("twg", ["bitbucket"] + args + ["--workspace", workspace, "--repo", repo, "--output", "json", "--output-summary", "none"],
                                          cwd: cwd, timeout: timeout, allowFailure: true)
        if result.status == 127 { throw CoreError.invalid("The TWG CLI is not installed. Install it, then run twg setup bitbucket.") }
        let value = try? JSONDecoder().decode(JSON.self, from: Data(result.output.utf8))
        guard let value, value["ok"].bool != false, result.status == 0 else {
            let message = value?["error"]["message"].string ?? "twg exited with status \(result.status)."
            let repair = value?["error"]["repair"].string.map { " " + $0 } ?? ""
            throw CoreError.invalid("Bitbucket: " + runner.redacted(message + repair))
        }
        return value
    }
    func twg(_ args: [String], project: Project, cwd: String? = nil, timeout: Double = 60) async throws -> JSON {
        try await Self.run(runner, args, remoteSlug: project.remoteSlug, cwd: cwd ?? project.repoPath, timeout: timeout)
    }

    func open(task: WorkTask, project: Project, summary: String, base: String, commitSHA: String) async throws -> PullRequest {
        guard project.host == .bitbucket else { throw CoreError.invalid("Bitbucket repository required.") }
        guard let branch = task.branchName, let cwd = task.worktreePath else { throw CoreError.invalid("Missing branch") }
        var existingPR: PullRequest?
        if task.pr != nil {
            existingPR = try await verifiedOpenPR(task: task, project: project)
        } else {
            // Recover an already-created PR after an interrupted response without duplicating it.
            let open = try await twg(["pull-requests", "query", "--state", "OPEN", "--source", branch, "--limit", "50"], project: project, cwd: cwd).array
            if let value = open.first(where: { $0["source"]["branch"]["name"].string == branch }), let number = value["id"].int, let url = value["links"]["html"]["href"].string {
                existingPR = PullRequest(number: number, url: url, baseBranch: value["destination"]["branch"]["name"].string ?? base)
            }
        }
        let body = try GitHub.changeDescription(summary)
        // Publish exactly the reviewed object, even if an editor moves the branch during publication.
        try await runner.pushReviewed(commitSHA, branch: branch, cwd: cwd)
        let file = root.appending(path: "projects/\(project.id)/pr-\(task.id).md")
        try body.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        if let existingPR {
            _ = try await twg(["pull-requests", "update", "--pull-request", String(existingPR.number), "--title", task.title, "--description-file", file.path, "--dest", base], project: project, cwd: cwd)
            return PullRequest(number: existingPR.number, url: existingPR.url, baseBranch: base)
        }
        let created = try await twg(["pull-requests", "create", "--title", task.title, "--source", branch, "--dest", base, "--description-file", file.path], project: project, cwd: cwd)
        guard let number = created["id"].int, let url = created["links"]["html"]["href"].string else { throw CoreError.invalid("Invalid Bitbucket PR response") }
        return PullRequest(number: number, url: url, baseBranch: created["destination"]["branch"]["name"].string ?? base)
    }

    func verifiedOpenPR(task: WorkTask, project: Project) async throws -> PullRequest {
        guard project.host == .bitbucket, let pr = task.pr, let branch = task.branchName else { throw CoreError.invalid("The task has no supported pull request.") }
        let value = try await twg(["pull-requests", "get", String(pr.number)], project: project, cwd: task.worktreePath)
        guard value["state"].string == "OPEN" else { throw CoreError.invalid("This pull request is no longer open. Create a new task for further changes.") }
        guard value["source"]["branch"]["name"].string == branch else { throw CoreError.invalid("The pull request branch no longer matches this task's worktree.") }
        return PullRequest(number: pr.number, url: pr.url, baseBranch: value["destination"]["branch"]["name"].string ?? pr.baseBranch)
    }

    /// Bitbucket reports an abbreviated head. Resolve the full SHA from the remote branch and require agreement.
    func remoteHead(branch: String, abbreviated: String, project: Project, cwd: String?) async throws -> String {
        let output = try await runner.run("git", ["ls-remote", "origin", "refs/heads/" + branch], cwd: cwd ?? project.repoPath).output
        let full = output.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard abbreviated.count >= 7, full.hasPrefix(abbreviated) else { throw CoreError.invalid("Bitbucket hasn’t caught up with the latest push. Waiting for it to refresh.") }
        return full
    }

    func status(task: WorkTask, project: Project) async throws -> HostedStatus {
        guard let pr = task.pr, project.host == .bitbucket else { throw CoreError.invalid("Bitbucket PR required") }
        let value = try await twg(["pull-requests", "get", String(pr.number), "--statuses"], project: project, cwd: task.worktreePath)
        guard let raw = value["state"].string, let abbreviated = value["source"]["commit"]["hash"].string else { throw CoreError.invalid("Incomplete Bitbucket status; merge is withheld.") }
        let state = raw == "OPEN" ? "OPEN" : raw == "MERGED" ? "MERGED" : "CLOSED" // DECLINED and SUPERSEDED end the PR without merging.
        let branch = value["source"]["branch"]["name"].string ?? ""
        guard state == "OPEN" else {
            return HostedStatus(state: state, head: abbreviated, branch: branch, base: value["destination"]["branch"]["name"].string ?? "", mergeState: "UNKNOWN", reviewDecision: "", draft: false, feedback: [], checks: [])
        }
        let head = try await remoteHead(branch: branch, abbreviated: abbreviated, project: project, cwd: task.worktreePath)
        var feedback: [ReviewFeedback] = []
        let comments = try await twg(["pull-requests", "comment", "query", String(pr.number), "--limit", String(Self.readLimit)], project: project, cwd: task.worktreePath).array
        guard comments.count < Self.readLimit else { throw CoreError.invalid("This pull request has more comments than Build Mate can inspect. Review it manually before merging.") }
        let byID = Dictionary(comments.compactMap { comment in comment["id"].int.map { ($0, comment) } }, uniquingKeysWith: { first, _ in first })
        for comment in comments {
            guard let id = comment["id"].int, comment["deleted"].bool != true, comment["pending"].bool != true,
                  let body = comment["content"]["raw"].string, !body.isEmpty, !Self.isOwnReply(body) else { continue }
            var root = comment
            for _ in 0..<100 { guard let parent = root["parent"]["id"].int, let next = byID[parent] else { break }; root = next }
            guard let rootID = root["id"].int else { continue }
            if root["inline"] != .null {
                guard root["resolution"] == .null else { continue } // Resolved conversations need no further action.
                let inline = root["inline"]
                var location = ""
                if let path = inline["path"].string { location = "On \(path)" + ((inline["to"].int ?? inline["from"].int).map { " line \($0)" } ?? "") + ":\n" }
                let outdated = inline["outdated"].bool == true ? "Comment on an older diff; verify whether it still applies.\n" : ""
                feedback.append(ReviewFeedback(id: "thread:\(id):" + GitHub.fingerprint(body), body: outdated + location + body, commentID: rootID, threadID: "comment:\(rootID)"))
            } else {
                feedback.append(ReviewFeedback(id: "comment:\(id):" + GitHub.fingerprint(body), body: body, commentID: rootID))
            }
        }
        let tasks = try await twg(["pull-requests", "task", "query", String(pr.number), "--limit", String(Self.readLimit)], project: project, cwd: task.worktreePath).array
        guard tasks.count < Self.readLimit else { throw CoreError.invalid("This pull request has more tasks than Build Mate can inspect. Review it manually before merging.") }
        for item in tasks where item["state"].string == "UNRESOLVED" {
            guard let id = item["id"].int, let body = item["content"]["raw"].string else { continue }
            feedback.append(ReviewFeedback(id: "task:\(id):" + GitHub.fingerprint(body), body: "Open pull request task (reply, and set resolve=true once it is fully done): " + body, threadID: "task:\(id)"))
        }
        let openTasks = tasks.filter { $0["state"].string == "UNRESOLVED" }.count
        let participants = value["participants"].array
        for participant in participants where participant["state"].string == "changes_requested" {
            let who = participant["user"]["account_id"].string ?? participant["user"]["display_name"].string ?? "reviewer"
            let name = participant["user"]["display_name"].string ?? "A reviewer"
            feedback.append(ReviewFeedback(id: "review:\(GitHub.fingerprint(who).prefix(16)):" + GitHub.fingerprint(who + (participant["participated_on"].string ?? "")),
                                           body: "\(name) requested changes. Address their comments and tasks on the pull request."))
        }
        let reviewDecision = participants.contains { $0["state"].string == "changes_requested" } ? "CHANGES_REQUESTED" : participants.contains { $0["approved"].bool == true } ? "APPROVED" : ""
        let conflicts = try await twg(["pull-requests", "conflicts", String(pr.number)], project: project, cwd: task.worktreePath).array
        let checks: [JSON] = value["_statuses"].array.filter { $0["commit"]["hash"].string == head }.map { status in
            var fields: [String: JSON] = ["name": status["name"] == .null ? status["key"] : status["name"], "detailsUrl": status["url"], "description": status["description"]]
            switch status["state"].string ?? "" {
            case "SUCCESSFUL": fields["conclusion"] = .string("SUCCESS")
            case "FAILED": fields["conclusion"] = .string("FAILURE")
            case "STOPPED": fields["conclusion"] = .string("CANCELLED")
            default: fields["status"] = .string("IN_PROGRESS")
            }
            if let run = Self.pipelineNumber(status["url"].string, slug: project.remoteSlug) { fields["runId"] = .string(run) }
            return .object(fields)
        }
        return HostedStatus(state: state, head: head, branch: branch, base: value["destination"]["branch"]["name"].string ?? "",
                            mergeState: conflicts.isEmpty ? "CLEAN" : "DIRTY", reviewDecision: reviewDecision, draft: value["draft"].bool ?? true, feedback: feedback, checks: checks, openTasks: openTasks)
    }

    /// The build number of a Bitbucket Pipelines result link for this repository, for example `…/pipelines/results/12`.
    static func pipelineNumber(_ raw: String?, slug: String) -> String? {
        guard let raw, let url = URL(string: raw), url.host?.lowercased() == "bitbucket.org",
              url.path.lowercased().hasPrefix("/" + slug.lowercased() + "/"), url.path.contains("pipelines") else { return nil }
        let parts = (url.path + "/" + (url.fragment ?? "")).split(separator: "/")
        guard let index = parts.firstIndex(of: "results"), index + 1 < parts.count else { return nil }
        let number = parts[index + 1]
        return number.allSatisfy(\.isNumber) ? String(number) : nil
    }

    func retarget(task: WorkTask, project: Project, base: String) async throws {
        guard let pr = task.pr else { throw CoreError.invalid("The task has no pull request.") }
        _ = try await twg(["pull-requests", "update", "--pull-request", String(pr.number), "--dest", base], project: project, cwd: task.worktreePath)
    }
    func ciRun(task: WorkTask, project: Project, runID: String) async throws -> CIRun {
        guard !runID.isEmpty, runID.allSatisfy(\.isNumber) else { throw CoreError.invalid("A numeric Bitbucket Pipelines build number is required.") }
        let run = try await twg(["pipeline", "get", "--pipeline", runID], project: project, cwd: task.worktreePath)
        return CIRun(head: run["target"]["commit"]["hash"].string ?? "", completed: run["state"]["name"].string == "COMPLETED",
                     failed: ["FAILED", "ERROR"].contains(run["state"]["result"]["name"].string ?? ""), attempt: run["run_number"].int ?? 1)
    }
    func ciLog(task: WorkTask, project: Project, runID: String) async throws -> String {
        try await twg(["pipeline", "get", "--pipeline", runID, "--logs", "--failed-steps", "--lines", "400"], project: project, cwd: task.worktreePath).text
    }
    func retryCI(task: WorkTask, project: Project, runID: String) async throws {
        _ = try await twg(["pipeline", "rerun-failed", "--pipeline", runID], project: project, cwd: task.worktreePath)
    }

    func receipt(_ token: String) -> String { Self.receiptPrefix + token + ")" }
    /// Build Mate's own replies end with an unquoted receipt line; a reviewer quoting one is still feedback.
    static func isOwnReply(_ body: String) -> Bool { body.split(whereSeparator: \.isNewline).contains { $0.hasPrefix(receiptPrefix) } }
    func existingReply(task: WorkTask, project: Project, feedback: ReviewFeedback, receipt: String) async throws -> String? {
        guard let pr = task.pr else { return nil }
        let comments = try await twg(["pull-requests", "comment", "query", String(pr.number), "--limit", String(Self.readLimit)], project: project, cwd: task.worktreePath).array
        return comments.first { $0["content"]["raw"].string?.contains(receipt) == true }?["id"].int.map { replyKey(feedback, id: $0) }
    }
    func postReply(task: WorkTask, project: Project, feedback: ReviewFeedback, body: String) async throws -> String {
        guard let pr = task.pr else { throw CoreError.invalid("The task has no pull request.") }
        var args = ["pull-requests", "comment", "create", "--pull-request", String(pr.number), "--text", body]
        if let parent = feedback.commentID { args += ["--reply-to", String(parent)] }
        let posted = try await twg(args, project: project, cwd: task.worktreePath)
        guard let id = posted["id"].int else { throw CoreError.invalid("Bitbucket did not confirm the review reply. It will be reconciled before retrying.") }
        return replyKey(feedback, id: id)
    }
    private func replyKey(_ feedback: ReviewFeedback, id: Int) -> String { "\(feedback.threadID?.hasPrefix("comment:") == true ? "thread" : "comment"):\(id)" }
    func resolve(task: WorkTask, project: Project, threadID: String) async throws {
        guard let pr = task.pr else { return }
        let parts = threadID.split(separator: ":")
        guard parts.count == 2, parts[1].allSatisfy(\.isNumber) else { throw CoreError.invalid("Unknown Bitbucket conversation.") }
        switch parts[0] {
        case "comment": _ = try await twg(["pull-requests", "comment", "resolve", "--pull-request", String(pr.number), "--comment", String(parts[1])], project: project, cwd: task.worktreePath)
        case "task": _ = try await twg(["pull-requests", "task", "resolve", "--pull-request", String(pr.number), "--task", String(parts[1])], project: project, cwd: task.worktreePath)
        default: throw CoreError.invalid("Unknown Bitbucket conversation.")
        }
    }

    func merge(task: WorkTask, project: Project, head: String) async throws {
        guard let pr = task.pr, let branch = task.branchName else { throw CoreError.invalid("The task has no pull request.") }
        let current = try await twg(["pull-requests", "get", String(pr.number)], project: project, cwd: task.worktreePath)
        guard current["state"].string == "OPEN", let base = current["destination"]["branch"]["name"].string else { throw CoreError.invalid("The pull request is no longer open.") }
        let target = try await twg(["branch", "query", "--query", base, "--limit", "100"], project: project, cwd: task.worktreePath).array.first { $0["name"].string == base }
        guard let target else { throw CoreError.invalid("Couldn’t read the merge settings for \(base).") }
        let allowed = target["merge_strategies"].array.compactMap(\.string)
        let strategy: String
        if let preferred = project.settings.mergeStrategy {
            strategy = switch preferred { case .squash: "squash"; case .mergeCommit: "merge_commit"; case .rebase: "fast_forward" }
            guard allowed.contains(strategy) else { throw CoreError.invalid("This repository doesn’t allow \(preferred.title.lowercased()) merges into \(base). Choose another merge method in Settings.") }
        } else {
            guard let preferred = target["default_merge_strategy"].string else { throw CoreError.invalid("Couldn’t read the repository’s default merge method.") }
            strategy = preferred
        }
        // TWG merges with merge commits, squash or fast-forward only.
        guard ["merge_commit", "squash", "fast_forward"].contains(strategy) else {
            throw CoreError.invalid("The repository’s default merge method (\(strategy)) isn’t supported. Choose a merge method in Settings.")
        }
        // Bitbucket cannot merge conditionally on a head commit, so re-verify the reviewed head immediately before merging.
        let remote = try await remoteHead(branch: branch, abbreviated: current["source"]["commit"]["hash"].string ?? "", project: project, cwd: task.worktreePath)
        guard remote == head else { throw CoreError.invalid("The pull request changed after review. Merge is withheld until the new head is verified.") }
        _ = try await twg(["pull-requests", "merge", "--pull-request", String(pr.number), "--merge-strategy", strategy, "--wait"], project: project, cwd: task.worktreePath, timeout: 150)
    }
}
