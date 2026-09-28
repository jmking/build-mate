# Architecture

Build Mate is one native macOS process. SwiftUI presents durable state from SQLite/GRDB; an `Orchestrator` actor dispatches work and reconciles external state. External tools run as child processes, not embedded SDKs.

## From an idea to a merge

1. Project chat inspects read-only checkouts of the linked repositories. It clarifies requirements, searches existing tasks, and proposes work or revises existing requirements. It creates tasks only after the user accepts a proposal or explicitly asks to queue them.
2. Each task targets one repository and enters Queue. Dependencies, explicit pauses, agent capacity, usage and overlapping file scopes govern dispatch. Cross-repository dependencies are supported; branch stacks stay in one repository.
3. The task gets an app-owned worktree based on the fetched default branch, or its approved stack parent. Codex plans and builds there, asking for clarification or plan approval when needed. Follow-up messages can revise active or reviewed work, including an existing PR.
4. Verification runs checks and captures required evidence. The agent receives the actual artifacts for self-review and fixes issues before human review. Proof is tied to both the commit and requirements revision; changes invalidate it.
5. After human review, publication pushes the verified commit and writes a short Markdown PR description. GitHub reconciliation reads reviews and CI, repairs routine issues, bounds retries and escalates decisions requiring human input. Merge respects repository rules and the reviewed head.

Task states are `todo` (Queue), `needs_clarification`, `building`, `human_review`, `in_pr`, `done`, and `canceled`. Planning/testing activity supplements these durable states; it does not replace them. `Models.swift` and `Orchestrator.swift` define transition guards. Do not write state directly from new UI code.

## Repository and storage identity

A project holds its name, instructions and shared settings. `ProjectRepository` records hold clone paths and hosting metadata. Every task has a repository ID; `store.project(for: task)` resolves the correct Git/hosting context. A renamed project keeps its repositories, task IDs, sessions and paths. Original Project repository fields remain for migration/discovery compatibility only.

Unlinking preserves repository files and historical identity. It is blocked while unfinished tasks or retained task worktrees depend on the link. Task deletion stops its processes and removes app-owned data/worktrees; existing PRs and branches are not deleted.

All app data is under `~/Library/Application Support/Build Mate/`: SQLite, generated workflow files, logs, attachments, proof, previews and task/project-chat worktrees. The checkout is not an app-data directory. Git maintains linked-worktree metadata in its normal Git directory.

## Agent integration

`AgentRunner` is a narrow process/protocol boundary. `CodexClient` is the only shipped implementation; `CodexRunner` maps native events into app-level events. There is no alternate model inference implementation. Codex owns authentication, native conversation context, compaction, configured tools and delegation.

Task and project sessions keep native thread IDs across runs. Delivery receipts avoid resending acknowledged user input, context or attachments. Model/effort selections are validated against the installed CLI catalog; explicit choices win. Project chat defaults to Astra High. Unsupported models fail visibly instead of silently falling back.

Task turns receive scoped worktree and Git-metadata write roots. Project chat is read-only. Only the parent can call lifecycle tools; child activity is recorded separately. Requests for unsupported approvals, permission expansion or secret entry are declined rather than silently granted. Desktop-specific capabilities are not guaranteed by the CLI integration.

Dynamic tool definitions are durable in older Codex threads. Compatibility paths are deliberately narrow: for example, older project threads can pass repository-targeted operations through the existing `note` envelope. Remove compatibility paths only with an explicit migration strategy.

The protocol was manually exercised with Codex CLI 0.157.1. If changing it, inspect the installed CLI’s generated schema and run a bounded, explicitly authorized integration probe. Generated schemas are not checked in: regenerate locally with `codex app-server generate-json-schema --out <temporary-directory>`. Do not run inference or service mutations as part of CI.

## Processes and recovery

`ProcessRunner` uses process groups so cancellation/timeouts also stop descendants. The scheduler persists intent before external mutations where necessary and reconciles after restart. PR publication and feedback handling recover from interrupted responses without duplicating actions. Project status exposes bounded, redacted wait reasons, session state, last run errors and background issues to the project agent. Messages saved while execution is blocked receive an immediate explanation. Human waits release execution capacity; internal proof/preview capacity is separate from the user’s agent-count setting.

PR monitoring requires Build Mate to remain running. An already-enqueued GitHub auto-merge can complete without it. The app cannot promise desktop-identical quality, speed, tool availability or token usage merely because model and effort match.

## UI and assets

`AppModel` presents database snapshots and routes UI commands into the core. Shared chat components handle streaming, typing motion, reactions, attachments and scrolling. Both composers use Return to send and Shift–Return to insert a newline at the selection. Drafts retain Markdown source, which renders as formatted text when sent. Native sheets and menus expose less frequent settings. Keep routine screens concise and surface details on demand. Chat follows content-size changes, including delayed typing bubbles, until the reader scrolls away. Native overlay scrollbars avoid permanent gutters. The working indicator reflects active sessions, not merely a Building state. Task edits save model/effort choices with the edit; the composer picker still applies immediately to the next turn. “QA approach” describes validation and optional recordings while retaining the existing proof storage format.

`BuildMate/BuildMate.icon` is the original app icon source, editable in Apple’s Icon Composer. Xcode generates the installed icon assets; old design mockups and exported icon previews are not build inputs.

## Current limits

- `PullRequestHost` has two implementations: `GitHub` (`gh`) and `Bitbucket` (`twg bitbucket …`, JSON output, failures reported as `ok: false`). Hosts translate commands and report `HostedStatus` in one normalized vocabulary; verified heads, bounded CI retries, exactly-once replies and merge approval stay in `HostedReview`. Bitbucket-specific details: the PR head is abbreviated, so the full SHA comes from `git ls-remote`; reply receipts are Markdown link references because Bitbucket shows HTML comments; open PR tasks are feedback that must be answered and resolved, and any open task withholds the merge; requested changes are enforced by Build Mate because Bitbucket may not enforce them; merges use the destination branch's default strategy unless the project overrides it. Missing PR automation never blocks coding. Existing project/task pauses remain explicit; resume them to start queued work.
- Local repositories build through human review; local-only merge/publication is not implemented.
- Claude, mobile/remote access, issue-tracker adapters, auto-updates and combined multi-task PRs are not implemented.
- Manual validation of a workflow is not evidence that every third-party tool, account, permission configuration or native UI automation setup behaves identically.
