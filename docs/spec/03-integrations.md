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
| Instruction changes | Fixed lifecycle developer brief; assemble current global/project instructions in every turn input. In 0.151, `thread/resume.developerInstructions` returned success but did not replace the original instruction in the manual probe. |

Every coding-task `turn/start` supplies `sandboxPolicy: { type: "workspaceWrite", writableRoots: [worktreePath], networkAccess: settings.network, excludeTmpdirEnvVar: true, excludeSlashTmp: true }`. The explicit exclusions prevent temporary-directory exceptions from broadening the write boundary. Resolve an unspecified model from `model/list`'s `isDefault` entry and send its ID explicitly.

### Automatic task titles
After saving a description-only task immediately, background naming uses a separate ephemeral `thread/start` and one `turn/start` with an output schema requiring `{ "title": "…" }`. Select the first available model from `gpt-6-luna`, `gpt-5.6-luna`, `gpt-5.4-mini`, `gpt-5.1-codex-mini` using `model/list`; require a supported `none`, `minimal` or `low` effort (in that order) and pass it explicitly on `turn/start`. Never inherit the project/default coding model. If none qualifies, keep the local title without inference. Use an empty app-owned `title-drafts/<uuid>` working directory, read-only sandbox, no network access, no Build Mate dynamic tools, and naming-only base instructions. Web search and the shell tool are disabled for this thread; unexpected server requests are rejected. Read the final `item/completed` agent message only after successful `turn/completed`, then stop the process and remove the scratch directory. No durable task session or worktree is created by naming.

RPC timeout is 5 seconds each; the title turn has a 20-second deadline. Manual edits and shutdown cancel background naming; the task is already saved and remains usable. Failures retain its local brief-derived title. Apply a successful refinement only if the original title/brief are unchanged, updating the title alone. Manual override skips Codex entirely. Real installed Codex verification on 2026-09-26 accepted ephemeral/read-only/schema parameters and returned a descriptive title in 3.69 seconds, with only user/agent message items.

### Build Mate tools for agents
Use **experimental client-side dynamic tools**, verified with codex-cli 0.151.0 on 2026-09-26. Initialize with `capabilities: { experimentalApi: true }`, then register `dynamicTools: [{ name, description, inputSchema }]` on `thread/start`. Handle `item/tool/call` server requests and reply on the same JSON-RPC ID with `{ contentItems: [{ type: "inputText", text: "…" }], success: true }`. Tools persist with the thread and survive `thread/resume` after restarting app-server. No MCP server or extra app process is required. Unsupported experimental registration is an actionable compatibility error, never a silent tool-less fallback.

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

`twg` is not installed on the spike Mac (2026-09-26). The [official catalog](https://developer.atlassian.com/platform/teamwork-graph/twg-cli/commands/commands-catalog/) confirms command families below, but does not specify all flags or JSON envelopes. **Use the exact REST contract as the mapping until authenticated CLI help and output are verified**; do not invent flags. `R` below means `https://api.bitbucket.org/2.0/repositories/{workspace}/{repo_slug}`; `P` means `R/pullrequests/{id}`. Substitute URL-encoded path segments. All bodies are JSON.

| Operation | Catalog command (flags/output unverified) | Exact REST fallback |
|---|---|---|
| Resolve repo/default branch | `twg bitbucket repo get` | `GET R`; read `full_name`, `mainbranch.name` |
| Create PR/stacked destination | `twg bitbucket pull-requests create` | `POST R/pullrequests`, body `{ "title": title, "description": summary, "source": {"branch":{"name":head}}, "destination":{"branch":{"name":base}}, "close_source_branch":true }` |
| State/approvals/participants | `twg bitbucket pull-requests get` | `GET P`; inspect `state`, `participants[].approved`, `reviewers`, `draft` |
| Build/commit statuses | `twg bitbucket pipeline query` (pipeline subset only) | `GET R/commit/{sha}/statuses`; follow `next` for all pages |
| Comments including inline/replies | `twg bitbucket pull-requests comment query` | `GET P/comments`; follow `next` |
| Comment/reply | `twg bitbucket pull-requests comment create` | `POST P/comments`, body `{"content":{"raw":text}}`; add `"parent":{"id":commentId}` for a reply, or `"inline":{"path":file,"to":line}` for an inline comment |
| Retarget destination | `twg bitbucket pull-requests update` (destination flag not established) | `PUT P`, body `{"destination":{"branch":{"name":base}}}` |
| Squash merge | `twg bitbucket pull-requests merge` | `POST P/merge`, body `{"merge_strategy":"squash","close_source_branch":true}`; handle asynchronous merge responses before marking Merged |

Do not implement a REST credential reader by scraping TWG configuration. Token transport for any needed fallback is still an authenticated-spike question; credentials stay with TWG or Keychain. Milestone 2 proceeds with GitHub; the Bitbucket provider remains disabled until verified. See 08 for exact installation/setup steps. At milestone 5 both verified hosts can implement the small `SCMProvider` contract (`openPR, prStatus, checks, comments, reply, retarget, merge`); do not add a second-provider abstraction to the GitHub-only core prematurely.

## 4. Editors, Terminal and Finder
- Detect installed apps with `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`:
  - Cursor `com.todesktop.230313mzl4w4u92`
  - Visual Studio Code `com.microsoft.VSCode`
  - Xcode `com.apple.dt.Xcode`
  - Terminal `com.apple.Terminal` (also offer iTerm2 `com.googlecode.iterm2`, Ghostty `com.mitchellh.ghostty` if installed)
- Icons: `NSWorkspace.shared.icon(forFile:)` on the app URL (the designs use these real icons, see `docs/design/assets/`).
- Open a folder: `NSWorkspace.shared.open([worktreeURL], withApplicationAt: appURL, configuration:)`. Show in Finder: `NSWorkspace.shared.activateFileViewerSelecting([url])`.
- Default editor: Settings › General "Open code in". The toolbar button shows the default editor's icon, with its name in the tooltip and accessibility label; its menu lists every installed editor.

## 5. Build Mate agent tools
Exposed to task agents (T) and the project agent (P). All calls are validated by Build Mate; Build Mate, not the agent, changes task state.

| Tool | Who | Purpose | Effect |
|---|---|---|---|
| `ask_question(prompt, options?, allowsFreeText, blocking?, suggestedAnswer?)` | T, P | Ask the user. | Creates a Question; blocking → `needs_clarification` (or "Decisions in PR" when in PR). Returns when answered. An optional explicit suggestion enables the confirmation sheet for Let the Agent Decide; no default is inferred. |
| `submit_plan(plan)` | T | Share the build plan. | If plan approval applies, creates an Approval and waits; else logs the plan and continues. |
| `request_review(summary, needsRecording, rationale, checks, recordingCommand?, screenshotsCommand?)` | T | Declare implementation complete and propose task-specific evidence. `checks` contains `{name, command}` entries. Legacy threads lacking newer fields can encode the full report as JSON in summary. Recording writes to `$BUILD_MATE_RECORDING_PATH`; before/after PNGs write to `$BUILD_MATE_BEFORE_PATH` / `$BUILD_MATE_AFTER_PATH`. | Triggers the proof runner; on success moves to `human_review` (or opens the PR if review is off). |
| `report_screenshot(path, caption)` | T | Future ad-hoc transcript screenshots. | Not registered in milestone 4: review screenshots are produced by the sandboxed `screenshotsCommand` and saved in media. |
| `note(text)` | T, P | Short progress note shown as an agent message. | |
| `propose_tasks(tasks[])` | P | Show a proposal card in the project chat. | Creates a Proposal; the user chooses Add to queue / Add to Backlog. |
| `create_tasks(tasks[]?, proposalId?, queueIndexes[], selectedIndexes[]?)` | P | Create tasks directly when the user explicitly asked ("go straight to Queue"). | Creates tasks atomically; returns their records. Indices are zero-based; selected items in queueIndexes go to Queue, the rest to Backlog. Refer to an existing proposal by proposalId to avoid duplicates. |
| `add_dependency(task, dependsOn)` | T, P | Record a newly discovered dependency. | Adds it and posts a Needs You notice (the user can remove it). |
| `refine_task(taskId, description)` | P | Refine an existing Backlog task when requested. | Updates the description only; rejects other states and other projects. |
| `project_status()` | P | Read tasks, states, open questions and PRs. | Read-only. |

### Naming latency and cost follow-up (2026-09-26)

Installed Codex `model/list` advertises GPT-5.6 Luna with low reasoning. A manual ephemeral, read-only, structured title turn returned “Compact Verbose CLI Output” in 4.388 seconds. Even the economical model is a network round trip, so this is never on the creation path. This probe is separate from automated tests. The [official model guide](https://learn.chatgpt.com/docs/models) recommends Luna for focused summaries; availability is determined by the installed CLI rather than assumed from the desktop app's picker.

### Project chat brought forward (2026-09-27)

Project threads register only the project tool set above (no build/review tools). `add_dependency` remains outside this increment; dependencies are validated within proposals and must point to earlier selected items. Shared/stacked PR controls remain milestone 5/v1.1.

Each message starts one read-only turn in `worktrees/<project-id>/project-chat`, refreshed from the locally available default-branch commit (no fetch or modifications in the user's working copy). Project/global instructions and current tasks/proposals are assembled on every turn. Both the thread and transcript persist. Responses stream into one durable message per Codex item; completed command output is expandable. Questions from dynamic tools or `item/tool/requestUserInput` appear in chat and Needs You. Unknown server requests are rejected. Read-only turn policy disables network access.

Project responses share the configured agent-slot limit, honour project/global pause, and stop on quit. The composer offers Stop during a response; additional messages wait until it finishes. Failures and interrupted responses expose Retry using the same thread; no automatic replay of task-creation actions. Accepting a proposal is transactional and idempotent. A repeated identical proposal for the same user message reuses the saved proposal. Stale/dismissed proposals and selections missing dependencies are rejected.
