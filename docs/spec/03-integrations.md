# 03 · Integrations

## 1. Codex app-server (agent runner)
Build Mate runs agents through `codex app-server` (JSON-RPC over stdio), the same engine the official Codex apps use. Protocol reference generated from `codex-cli 0.151.0`: `docs/reference/codex-app-server-schema/` (regenerate with `codex app-server generate-json-schema --out <dir>` and diff when Codex updates).

### Auth and account
- Sign-in is owned by Codex (ChatGPT account). Build Mate reads status with `account/read` and starts sign-in with `account/login/start` if needed. Build Mate never handles ChatGPT credentials.
- Usage meter: `account/rateLimits/read` on launch and the `account/rateLimits/updated` notification afterwards (see 02 §12). `account/usage/read` MAY back a usage detail popover.

### Models
- `model/list` populates the model pickers (Settings › General and per task in v1.1). Never hard-code model IDs; the list depends on the account.

### Sessions (one Codex thread per task, one for each project chat)
| Build Mate action | App-server call |
|---|---|
| Start a task session | `thread/start` with `cwd` = worktree, `model`, `sandbox`, `approvalPolicy` (never ask; Build Mate handles approvals at the task level), `developerInstructions` = assembled prompt layers 1–3 (02 §7). Then `turn/start` with the task input. |
| Next turn (continuation) | `turn/start` on the same thread. |
| Resume after a pause, question or review | `thread/resume` by `threadId`, then `turn/start` with the answer/note as input. |
| Message a running agent | `turn/steer` with `expectedTurnId` = active turn, so the agent sees it during its current turn. If no turn is active, `turn/start`. (The Building composer placeholder in the designs says "It reads this on its next turn"; use "Message the agent" instead.) |
| Pause task | `turn/interrupt` after the current item completes (wait for `item/completed`), then do not start another turn. |
| Attachments | Images as `localImage` inputs. Video: extract key frames (1 per 2 s, max 20) as `localImage` plus the audio track as `localAudio` (or a transcript as text if audio input is unavailable for the model). |
| Activity feed | `item/started`, `item/completed`, `item/commandExecution/outputDelta`, `item/fileChange/*`, `turn/diff/updated`, `item/agentMessage/delta`, `turn/plan/updated`. Group consecutive tool items into one `activity` message. |
| Token counts | `thread/tokenUsage/updated`. |
| Stall detection | Time since the last notification on the thread. |
| Instruction changes | Applied on the next `turn/start` by passing updated instructions (verify whether `developerInstructions` can be updated mid-thread; otherwise inject via `thread/inject_items`). |

### Build Mate tools for agents
Agents need a few Build Mate-specific tools (§5). Two mechanisms, in order of preference:
1. **Dynamic tools** (client-side): the app-server sends `item/tool/call` (`DynamicToolCallParams`) and Build Mate responds. The schema contains `DynamicToolSpec`, but tool registration is not in the stable `thread/start` params in 0.151; treat as experimental and verify (08).
2. **MCP server** (fallback, stable): the helper runs a local MCP server (stdio) and registers it per session with `thread/start` `config` override `mcp_servers.buildmate = { command, args }`.
Also handle `item/tool/requestUserInput` (Codex's own ask-the-user request) by converting it into a Build Mate Question.

## 2. GitHub (via `gh`)
Build Mate uses the user's authenticated GitHub CLI. It checks `gh auth status` when a GitHub project is added and guides the user to `gh auth login` if needed. No tokens stored by Build Mate.

| Operation | Command |
|---|---|
| Resolve repo from the clone | `gh repo view --json nameWithOwner,defaultBranchRef,url` (run in repoPath) |
| Push branch | `git push -u origin <branch>` (from the worktree) |
| Open PR | `gh pr create --base <base> --head <branch> --title <t> --body-file <f>` (add `--draft` only if configured) |
| PR status | `gh pr view <n> --json state,isDraft,mergeable,mergeStateStatus,reviewDecision,reviews,latestReviews,statusCheckRollup,comments,headRefName,baseRefName,url` |
| Checks detail / logs | `gh pr checks <n> --json name,state,link,startedAt,completedAt` and `gh run view <id> --log-failed` |
| Review comments (inline) | `gh api repos/{owner}/{repo}/pulls/{n}/comments` and replies via `gh api -X POST .../comments/{id}/replies` |
| Comment | `gh pr comment <n> --body-file <f>` |
| Retarget stacked PR | `gh pr edit <n> --base <branch>` |
| Merge | `gh pr merge <n> --squash --delete-branch` (never `--admin`) |

## 3. Bitbucket Cloud (via TWG CLI)
Bitbucket Cloud projects use Atlassian's **Teamwork Graph CLI** (`twg`), which supports Bitbucket repos, PRs, branches, commits, pipelines and deployments. Bitbucket uses a separate Bitbucket token configured with `twg setup bitbucket` (Bitbucket is not on TWG's OAuth). Build Mate checks setup when a Bitbucket project is added and guides the user through it; no tokens stored by Build Mate.

Required operations (map each to the TWG command from Atlassian's Command Catalog during the spike; record the exact commands here):

| Operation | TWG command (verify) | Fallback |
|---|---|---|
| Resolve repo, default branch | `twg` repo info | `git remote get-url origin` + Bitbucket REST `GET /2.0/repositories/{ws}/{repo}` |
| Open PR (with destination branch for stacking) | `twg` PR create | REST `POST /2.0/repositories/{ws}/{repo}/pullrequests` |
| PR status: state, approvals, participants | `twg` PR get | REST `GET .../pullrequests/{id}` |
| Build status (Pipelines and commit statuses) | `twg` pipelines / commit status | REST `GET .../commit/{sha}/statuses` |
| Comments incl. inline, replies | `twg` PR comments | REST `.../pullrequests/{id}/comments` |
| Update destination (restack) | `twg` PR update | REST `PUT .../pullrequests/{id}` |
| Merge (squash, close source branch) | `twg` PR merge | REST `POST .../pullrequests/{id}/merge` with `merge_strategy: squash`, `close_source_branch: true` |

Implementation: both hosts sit behind one `SCMProvider` protocol (`openPR, prStatus, checks, comments, reply, retarget, merge`) so the orchestrator never branches on host. Output parsing MUST use structured output (JSON) where the CLI provides it.

## 4. Editors, Terminal and Finder
- Detect installed apps with `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`:
  - Cursor `com.todesktop.230313mzl4w4u92`
  - Visual Studio Code `com.microsoft.VSCode`
  - Xcode `com.apple.dt.Xcode`
  - Terminal `com.apple.Terminal` (also offer iTerm2 `com.googlecode.iterm2`, Ghostty `com.mitchellh.ghostty` if installed)
- Icons: `NSWorkspace.shared.icon(forFile:)` on the app URL (the designs use these real icons, see `docs/design/assets/`).
- Open a folder: `NSWorkspace.shared.open([worktreeURL], withApplicationAt: appURL, configuration:)`. Show in Finder: `NSWorkspace.shared.activateFileViewerSelecting([url])`.
- Default editor: Settings › General "Open code in". The toolbar button shows the default editor's name and icon; its menu lists every installed editor.

## 5. Build Mate agent tools
Exposed to task agents (T) and the project agent (P). All calls are validated by the helper; the helper, not the agent, changes task state.

| Tool | Who | Purpose | Effect |
|---|---|---|---|
| `ask_question(prompt, options?, allowsFreeText, blocking)` | T, P | Ask the user. | Creates a Question; blocking → `needs_clarification` (or "Decisions in PR" when in PR). Returns when answered. |
| `submit_plan(plan)` | T | Share the build plan. | If plan approval applies, creates an Approval and waits; else logs the plan and continues. |
| `request_review(summary)` | T | Declare implementation complete. | Triggers the proof runner; on success moves to `human_review` (or opens the PR if review is off). |
| `report_screenshot(path, caption)` | T | Attach a screenshot to the chat or proof. | Stored in media. |
| `note(text)` | T, P | Short progress note shown as an agent message. | |
| `propose_tasks(tasks[], shipAs)` | P | Show a proposal card in the project chat. | Creates a Proposal; the user chooses Start Now / Add to Backlog. |
| `create_tasks(tasks[], destination: backlog|todo)` | P | Create tasks directly when the user explicitly asked ("go straight to Todo"). | Creates tasks; returns their numbers. |
| `add_dependency(task, dependsOn)` | T, P | Record a newly discovered dependency. | Adds it and posts a Needs You notice (the user can remove it). |
| `project_status()` | P | Read tasks, states, open questions and PRs. | Read-only. |
