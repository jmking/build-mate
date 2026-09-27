# 02 · Architecture

## 1. Components
Build Mate v1 is **one macOS app process**. No separate helper, no XPC, no local server.

```
┌──────────────────────────── Build Mate.app (Swift 6, SwiftUI, macOS 26+) ────────────────────────────┐
│ UI: main window · menu bar extra · Settings · notifications                                          │
│ Core: orchestrator (Symphony model) · SQLite store · worktrees · hooks · proof · previews · SCM · Codex │
└──────────────┬───────────────────────────────┬──────────────────────────────────┬─────────────────────┘
               │ spawns                        │ shells out                       │ reads/writes
     codex app-server (one per session)   git · gh · twg · hook commands    ~/Library/Application Support/Build Mate/
```

- The UI observes the core directly (`@Observable` models on the main actor; orchestration work in actors/tasks).
- **Keeps working with the window closed**: closing the last window does not quit the app; the menu bar extra stays. A "Open at login" setting (`SMAppService.mainApp`) keeps it running after restarts.
- **Quitting** with agents working asks: "N agents are working. Pause them and quit?" Pausing is safe; sessions resume on next launch.
- Add a separate background helper only if a real requirement appears (for example agents must keep running after the user quits). v2 remote access adds an HTTPS listener inside the same app.

Language: Swift 6, SwiftUI (AppKit where SwiftUI lacks a control), structured concurrency. Persistence: SQLite through GRDB in WAL mode (the only third-party dependency planned for v1).

## 2. Relationship to Symphony
Build Mate adapts Symphony's orchestration model (`openai/symphony` `SPEC.md`) in Swift. It does not ship the Elixir reference implementation.

| Symphony concept | Build Mate |
|---|---|
| Tracker adapter (`tracker.kind`) | Built-in tracker backed by SQLite. Linear/Jira adapters are v3. |
| `WORKFLOW.md` (front matter + prompt body) | Generated per project into Build Mate storage from the project's settings and instructions, never committed. Kept so the configuration stays portable and could later be exported to the repo (v3). |
| Active / terminal states | Active: `todo` (dispatch candidates), `building`, `in_pr` (watch mode). Waiting on a human: `needs_clarification`, `human_review`. Terminal: `done`, `canceled`. |
| `blocked_by`, `dispatchable` | Task dependencies and the pause flag. A task is dispatchable only if not paused, its project is not paused, all dependencies are merged (or its stack base PR exists, see 9), and no approval is pending. |
| Workspace per issue, hooks (`after_create`, `before_run`, `after_run`, `before_remove`) | Git worktree per task plus the same four hooks, configured per project. |
| Run attempt, retry with backoff (`min(10000·2^(n-1), max_retry_backoff_ms)`), continuation retry (1 s) | Same semantics and defaults. |
| `max_concurrent_agents`, per-state limits | "Agents at once" (default 4) plus a heavy-step limit (default 2) for proof recording and previews. |
| Reconciliation (stop sessions whose issue left an active state) | Same. Used for pause, cancel. |
| Codex app-server as the agent | Same. Codex is the only runner in v1; introduce an abstraction only when a second runner (Claude, v3) is actually built. |
| Status API | Not needed; the UI reads the core directly. |

The targeted audit and deliberate deviations are recorded in [09-symphony-audit.md](09-symphony-audit.md). Live workers waiting for an answer or approval still reserve a concurrency slot. `afterRun` failures are diagnostic; `beforeRemove` failures abort removal to preserve work.

Extensions beyond Symphony: clarification questions, plan approval, proof of work, human review, PR watch mode, project chat and task creation, stacked PRs, pause, previews, remote control.

## 3. Storage (nothing in the repo)
Root: `~/Library/Application Support/Build Mate/`

| Path | Contents |
|---|---|
| `buildmate.sqlite` | All projects, tasks, sessions, messages, questions, approvals, proof metadata, settings. |
| `projects/<project-id>/WORKFLOW.md` | Generated Symphony-style workflow for the project (front matter from settings, body from instructions). Regenerated on every settings or instructions change. |
| `projects/<project-id>/media/` | Attachments, recordings, screenshots, extracted video frames. Location overridable per project (large files). |
| `worktrees/<project-slug>/<task-number>/` | Task worktrees created with `git worktree add` from the user's clone. |
| `logs/` | App and per-session logs (rotated, 14 days). |

Rules:
- Build Mate MUST NOT create, modify or commit files in the user's clone other than through git operations on task branches. It MUST NOT add `.gitignore` entries or config files.
- Worktree bookkeeping lives in the clone's `.git/worktrees/` (local, never pushed). Removing a task removes its worktree (`git worktree remove`, after `before_remove`).
- After a confirmed merge, remove the task worktree once its worker stops. Keep the task, transcript, proof and local branch. Run `beforeRemove`; never force removal of dirty worktrees. Failed cleanup is reported and retried on the next reconciliation poll, including after restart.
- Deleting a project removes its data and worktrees, never the user's clone.

## 4. Data model
All IDs are UUIDs unless stated. Timestamps are UTC.

**Project**: `id, name (display, e.g. acme/web), repoPath, host (local|github|bitbucket), remoteSlug (owner/repo or workspace/repo), defaultBranch, instructions (markdown), settings (Settings), paused (bool), createdAt`.

**Settings** (per project; global defaults in app settings):
- `agentsAtOnce` (global, default 4), `heavyStepsAtOnce` (global, default 2), `maxTurnsPerTask` (default 20), `retryBackoffMaxMs` (300000), timeouts (turn 3 600 000 ms, stall 300 000 ms, read 5 000 ms).
- `askBefore`: `{ build: false, openPR: true, merge: false }`.
- `prStrategy`: `separateStacked` (default) | `onePR` (v1.1).
- `branchPrefix` (default empty, meaning `<number>-<slug>`; e.g. `427-report-permissions`).
- `editor` (bundle id, default the first installed of Cursor, VS Code, Xcode).
- `hooks`: `{ afterCreate, beforeRun, afterRun, beforeRemove }` shell strings, timeout 60 s each.
- `proof`: `{ checks: [{ name, command, required }], recording: { command | agentDriven }, screenshotsForUI: bool }`.
- `preview`: `{ command, portEnvVar (default PORT), readyPath (default /) }`.
- `sandbox`: `{ network: true }`.
- `model`: default Codex model and reasoning effort for task agents. A task-specific choice overrides these defaults; project chat has its own choice, defaulting to Astra High.

**Task**: `id, projectId, number (int, unique per project), title, description (markdown), state (see 5), paused (bool), rank (float, ordering within Queue), dependsOn [taskId], shipAs (own | stackOn(taskId) | featureBranch(name) v1.1), askBeforeBuild (inherit|on|off), proofRequirement (automatic|checksOnly|checksAndRecording), origin (chat|sheet|phone), branchName, worktreePath, pr { number, url, baseBranch } ?, retry { attempt, dueAt, error } ?, createdAt, updatedAt, doneAt`.

**Attachment**: `id, ownerType (task|message), ownerId, kind (image|file), path, filename, byteSize, durationSec?, frames [path]?, transcript?, sourceAttachmentId?, removedAt?`.

**AgentConfiguration**: `id (task or project UUID), model, effort?`. Store explicit conversation choices separately from task/project lifecycle records so concurrent lifecycle writes cannot overwrite them. Missing task configuration inherits project/default Codex settings; missing project-chat configuration means `gpt-6-astra` / `high`.

**Session**: `id, ownerType (task|project), ownerId, codexThreadId, status (idle|running|waiting|stalled|failed|ended), currentTurn, activeModel?, activeEffort?, turnCount, tokensIn, tokensOut, startedAt, lastEventAt`. Active model/effort describe the last started turn, allowing the UI to distinguish a saved change from a response already in progress.

**Message** (the chat log for tasks and projects): `id, sessionId, role (user|agent|system), kind (text|question|plan|proposal|activity|event|proof), body (markdown), payload (JSON per kind), createdAt`.
- `activity` groups tool calls into one collapsible row ("Worked for 12 min · 18 commands · 3 files edited") with the raw events kept for the expanded view.
- `event` is a state change or system note ("Moved to Human review").

**Question**: `id, taskId, messageId, prompt, options [string], allowsFreeText, blocking (bool), answer?, answeredBy (user|agentDefault), answeredAt?`.

**Approval**: `id, taskId, kind (plan|openPR|merge), status (pending|approved|rejected), planText?, createdAt, resolvedAt?`.

**Proof**: `taskId, rationale, recordingRequired, recording { path, durationSec }?, screenshots [beforePath, afterPath], commitSHA?, checks [{ name, status (passed|failed|skipped), durationSec, logPath }], changes { files, additions, deletions, summary, perFile [{path, additions?, deletions?}] }, complete (bool), producedAt`.

**RunAttempt** (Symphony): `id, taskId, attempt, phase, startedAt, endedAt, status (succeeded|failed|timedOut|stalled|canceled), error`.

**Proposal** (project chat): `id, projectId, messageId, tasks [{ title, description, dependsOnIndex [int] }], shipAs, status (open|created|dismissed), createdTaskIds` (ordered accepted-task links; used for idempotent acceptance).

**Device** (v2): `id, name, kind (mac|iphone), publicKey, lastSeenAt`.

## 5. Task lifecycle

### States
`todo → needs_clarification ↔ building → human_review → in_pr → done` (plus `canceled`). `paused` and `retrying` are flags, not states.

The persisted `done` state is displayed as **Merged** throughout the app. Keep the storage value unchanged for existing tasks.

Existing legacy backlog tasks migrate to Queue after already queued work, preserving their internal priority, pause flags, dependencies and content. New tasks always start in Queue. Unaccepted proposals remain in project chat.

### Transitions
| From | To | Trigger | Guard / notes |
|---|---|---|---|
| (new) | todo | Every task created by project chat, the New Task sheet or proposal acceptance | |
| todo | (dispatched) | Scheduler | Dispatchable (section 2) and a slot is free. Highest rank first. |
| dispatched | needs_clarification | Agent calls `ask_question` with `blocking: true` during its first ("understand") turn | |
| dispatched | todo + pending plan approval | `askBeforeBuild` effective and agent calls `submit_plan` | Task stays in Queue; appears in Needs You › Approvals. |
| todo (plan approved) / dispatched | building | Plan approved, or no approval needed and no blocking questions | |
| needs_clarification | building | All blocking questions answered, or user presses **Let the agent decide** (agent proceeds with stated defaults) | Dependencies must still be satisfied; otherwise it waits in Queue showing "Waits on #n". |
| building | needs_clarification | Agent asks a blocking question mid-build | Session paused until answered. |
| building | human_review | Agent calls `request_review` and proof is complete | If `askBefore.openPR` is off, go straight to opening the PR (in_pr). |
| building | (proof failed) | Proof runner reports a required check or recording failed | Agent gets the failure and continues building; after 3 consecutive proof failures raise a Needs You item. |
| human_review | in_pr | User: **Open Pull Request** | Agent pushes the branch and opens the PR (stacked base if needed). |
| human_review | building | User sends chat feedback during review | Feedback is sent as the next user message; proof is invalidated and pause flags are preserved. |
| in_pr | in_pr (watching) | CI fails, review comments, merge conflicts | Agent fixes on its own and pushes. Decisions become blocking questions shown under "Decisions in PR". |
| in_pr | done | PR merged (by the agent if `askBefore.merge` is off and required checks + approvals pass; by the user or anyone on the host) | |
| in_pr | pending merge approval | `askBefore.merge` on and PR is mergeable | Needs You › Approvals: **Merge**. |
| any active | canceled | User: Cancel task | Session stopped, worktree kept until the user deletes the task. PR closed only if the user confirms. |
| any | (paused flag) | Pause task / project / all | See section 10. |

### Task edits
Title-only edits preserve lifecycle and proof. A scope edit (brief or proof preference) is an atomic replan operation: block dispatch/publication during the edit, pause any started task, interrupt and await its worker, then save the new fields, invalidate proof, supersede prior plan approvals and resolve pending questions as superseded. Started tasks return to Queue paused; unstarted drafts keep their state and pause flag. Resume reuses the existing thread/worktree with the current task prompt. Old answers remain historical context; superseded unanswered questions are excluded from the new prompt. Scope edits are rejected once a PR is opening/open or the task is terminal. This does not add a general-purpose Building → Queue transition.

### Road to merge (display)
Five checkpoints derived from state and data: **Clarified** (no open blocking questions and, if needed, plan approved), **Built** (agent requested review), **Proof of work** (proof complete, with sub-items Checks and, when applicable, Recording), **Human review** (approved, or skipped by settings), **Merged**. Each is `done`, `current`, `needsYou` or `todo`. The 5-segment bar on cards and the vertical checklist in the task inspector are two renderings of the same data.

## 6. Orchestration loop
Follow Symphony's loop with these specifics:
- **Tick** every 5 s locally (no external tracker to poll). SCM status (CI, reviews, comments) for tasks in `in_pr` is polled every 60 s per task, with backoff to 5 min when nothing changes for 30 min. Webhooks are out of scope for v1.
- **Dispatch**: pick dispatchable Queue tasks by rank; respect `agentsAtOnce` across all projects and per-project pause.
- **Workspace**: on first dispatch, create the branch from `defaultBranch` (or from the stack base branch) and a worktree; run `afterCreate`. Before every run attempt run `beforeRun`; after, `afterRun`. Hook subprocesses run in private process groups; timeout/cancellation terminates their descendants too. Failed setup is retried in the existing worktree; `afterCreate` is retried until it succeeds, then never repeated for that worktree.
- **Session**: one Codex thread per task, resumed across attempts and across human-in-the-loop pauses so the agent keeps its context (verify thread resume in spike, see 08). If resume is not possible, start a new thread and replay the task's message history as context.
- **Turns**: each turn continues until the agent ends it, then the next turn starts automatically up to `maxTurnsPerTask`, unless the agent is waiting (question, approval, review) or the task is paused.
- **Stall detection**: no Codex event for `stall` ms marks the attempt stalled and schedules a retry.
- **Reconciliation** every tick: stop sessions for tasks that are paused, canceled, or whose project is paused.

## 7. Prompt assembly
For each task session Build Mate builds the initial prompt from, in order:
1. **Build Mate system brief**: the lifecycle, the tools available (03, section 5), the rules (ask, don't guess; stay in scope; proof is required; never write outside the worktree).
2. **Global instructions** (Settings › Instructions).
3. **Project instructions** (sidebar › Instructions). Project instructions override global ones on conflict.
4. **Task**: title, description, attachments (images inline; videos as key frames and transcript, see 03), answers to questions so far, approved plan, dependency context (what the tasks it depends on changed), and the current goal for its state.

The repo's own `AGENTS.md` is read by Codex natively from the worktree; Build Mate does not copy it. Instruction changes apply from the next turn of every running session. In Codex 0.151, the fixed developer brief delegates current project/global instructions to the freshly assembled text input each turn; the resume override did not replace existing instructions in the spike (08).

The **project agent** gets 1–3 plus a project brief (repo summary, open tasks and their states) and the `propose_tasks` / `create_tasks` tools. It runs read-only in a dedicated worktree of the default branch, refreshed from the locally available default-branch commit on each new chat turn. Each message drives one turn, sharing the task-agent concurrency limit and project/global pause. Project questions are durable chat-message payloads (the task Question table retains its task foreign key). Open proposals and created-task links survive restarts.

## 8. Proof of work
- **Task-specific evidence**: New Task defaults to Automatic. The agent chooses whether a recording is needed based on visual versus functional work and explicit user instructions, explains the choice in its plan and submits a rationale. The user can override with Checks only or Checks + recording; the app enforces that choice. Existing tasks migrate to Automatic. The former project-wide `recordingRequired` setting is retired.
- **Checks** run by Build Mate in the worktree after `request_review`: project-configured checks plus agent-proposed named commands, with exit code, duration and log. Agent checks are required and at least one required check must exist and pass. No recording setup is needed to start work. A check demonstrates behavior; documentation-only work can use a relevant content/format check.
- **Command boundary**: proof commands run under the macOS sandbox with writes restricted to the task worktree and its app-owned media directory (including a private TMPDIR). Network follows the project setting. Agent-proposed commands never run as unrestricted shell hooks. Command success is independently measured; the relevance of agent-chosen evidence still needs human review.
- **Recording**, only when selected by the agent or required by the user: either a configured command that writes a video (for example a Playwright script with video on, using the task's preview port), or agent-authored browser automation executed by the proof runner as a recording command. Output: MP4/H.264, max 3 minutes, saved to `media/`.
- **Screenshots**: for UI changes when enabled, before (default/base branch) and after (task branch). The agent supplies `screenshotsCommand`, executed within the same proof sandbox, writing PNGs to `$BUILD_MATE_BEFORE_PATH` and `$BUILD_MATE_AFTER_PATH`. Build Mate decodes both images before accepting proof. Checks only suppresses visual evidence. Image contents still require human review; successful decoding cannot establish semantic correctness.
- **Changes summary**: files changed, additions, deletions, and a concise agent summary in readable Markdown, with paragraphs/bullets where useful. The review and Changes views render block Markdown. For older saved summaries containing a JSON object or array, display its fields as headings and lists, retaining all values (including limitations and unknown fields) without rewriting the original evidence. The legacy summary-only tool still accepts an outer JSON report; its inner summary must be Markdown, not another encoded report.
- The configured or agent-proposed recording command receives an absolute `$BUILD_MATE_RECORDING_PATH` in project media storage and must write MP4/H.264 there. The core verifies an H.264 video track and duration in (0, 180] seconds. A missing required command or recording fails proof.
- Proof is `complete` when every required item exists and passed and the implementation is committed (a dirty worktree fails proof). Only then can the task enter Human review. Save the verified commit SHA and reject PR publication if HEAD or the worktree changes afterward. Older proof without a SHA must be refreshed by messaging the agent in chat. Review chat saves feedback, invalidates proof, returns to Building and resumes the same thread; task/project/global pause remains in effect. Three consecutive proof failures pause the task and create a Needs You Fix item; explicit Resume starts a new failure allowance.
- Proof stays in Build Mate. It is **not** added to PR descriptions (the team should not see Build Mate artefacts).

## 9. Pull requests and stacking
- One PR per task by default. Title from the task title; body is the agent's plain change summary only: no proof, no Build Mate footer or branding.
- **Stacked**: when task B depends on task A and A's PR is not merged, B's branch is created from A's branch and B's PR targets A's branch. When A merges, the agent rebases B onto the default branch, retargets the PR, force-pushes with lease, and re-runs checks. The In PR inspector shows the stack.
- **Ship as one PR** (v1.1): tasks merge into a shared feature branch; one PR from it to the default branch with combined proof.
- **Merging**: squash merge by default, delete branch after merge, never bypass branch protection or required reviews.

## 10. Pause
| Scope | Control | Behaviour |
|---|---|---|
| Task | Task toolbar **Pause** (⌘.) | Agent finishes the current tool call/step, then the session stops; task stays in its column with a Paused marker; nothing dispatches it. **Resume** continues the same thread. |
| Project | Board toolbar **Pause Project** | No new dispatch in the project; running tasks pause as above. Sidebar shows a pause glyph. Questions still reach Needs You. |
| Everything | Sidebar footer, menu bar, iPhone (⌥⌘P) | All projects paused. A banner in every window: "All agents paused · Resume". |
Pause never discards work. Paused time does not count toward timeouts.

## 11. Previews (Run locally / Open Preview)
- Each task gets a port from a pool (default 4100–4199) when a preview is requested. Build Mate runs `preview.command` in the worktree with `portEnvVar` set, waits until `readyPath` responds (timeout 90 s), then opens `http://127.0.0.1:<port>/` (the configured ready path is only for readiness checks). Pass `HOST=127.0.0.1`; the configured command must bind locally and respect the supplied port. Readiness requires an HTTP 2xx/3xx response at this host/port. Previews count against the heavy-step limit for their lifetime; a busy limit explains how to free a slot. Repeated requests reuse the running preview. Stop, quit, review chat feedback, scope edits, deletion and merge cleanup terminate the child process group and free its slot. Startup failure/timeout shows redacted output. Previews stop 30 minutes after the last Run/Open from Build Mate (browser activity cannot be observed). A missing command opens configuration; Build Mate does not guess or install a project toolchain. Native/CLI tasks can use editor and Terminal instead.
- v1.1: a local reverse proxy maps `<task-number>.localhost` to the preview port.

## 12. Notifications and usage
- macOS notifications for every new Needs You item, grouped by project, with actions where possible (answer options, Approve Plan, Open). Respects Focus.
- **Usage meter**: shows the ChatGPT plan usage window reported by Codex (e.g. "62% of this 5-hour window left · resets 16:40") in the sidebar footer and the menu bar. Setting: "Hold new tasks when usage is below N%" (default 15%). When held, Queue tasks show "Waiting for usage". (Not yet drawn; design it with the sidebar footer and menu bar styles.)

## 13. Remote control (v2)
- The app exposes its API over HTTPS on a private network interface only (for example a Tailscale address). Nothing listens on public interfaces.
- **Pairing**: Settings › Remote › Pair a Device shows a QR code with a one-time code and the host key; the device stores its key pair in the Keychain. Every request is signed. Devices can be removed.
- **Keep awake**: when enabled, the app holds a power assertion while any agent is working.
- **Push**: the app writes Needs You events to the user's private CloudKit database; the iPhone app subscribes and receives notifications. No Build Mate server.
- **Open Preview** on iPhone opens the task's preview through the private network address.

## 14. Security
- Agents run with Codex's sandbox: writes limited to their worktree plus the Git metadata necessary to stage and commit on its assigned branch (private worktree metadata, shared objects, that branch’s ref/reflog and lock files). The main checkout, shared Git configuration/hooks and other branch refs remain read-only; network on by default (package installs), per-project switch.
- The app runs hooks and checks as the user. Hooks are shown in Settings › Hooks and changes require confirmation.
- No tokens are stored by Build Mate for GitHub/Bitbucket; it uses the logged-in `gh` and `twg` CLIs. Codex auth is owned by Codex (ChatGPT sign-in).
- Logs redact tokens and environment variables matching common secret patterns.


### Chat attachment ownership and cleanup (2026-09-27)

Copy sent attachments into `projects/<project-id>/media/<task-or-project-id>/<message-id>/`; never depend on the original Desktop/Downloads path. Message insertion and attachment records are atomic; import failure removes partial copies. Up to 20 files per message, 50 MB each; reject folders and unreadable images. Images retain their original bytes and a normalized vision PNG. File bytes do not enter logs.

Tasks created from a project proposal inherit copies of the chat attachments available when that proposal was made. Each task copy records its `sourceAttachmentId`. Confirmed merge deletes that task's attachment files (including normalized images). The project-chat source is removed only once every task linked to it has merged. Unassigned project files remain until project deletion; no age-based purge. Originals outside Build Mate and proof evidence are untouched. Keep metadata tombstones and transcript text; show “attachment removed” instead of a broken preview. Recovery retries merge cleanup after interruption.

### Usage holds and app lifetime

The app reads account usage before first dispatch and then every 60 seconds, also consuming live task rate-limit events. Below the configurable threshold (15% default), new task attempts and project-chat responses wait; active workers keep their slots and continue. Unknown usage is not interpreted as zero, and failed reads retain a last-known low-usage hold. Resume Anyway overrides the hold until usage recovers or the app restarts. Global settings decoding supplies defaults for databases created before usage holds existed.

The main SwiftUI Window, Settings and MenuBarExtra share one AppModel and one orchestrator. AppDelegate owns the observation task through window closure. Native notification receipts are stored in `notification-receipts.json` beneath app storage, keyed by the durable attention event; notification actions resolve the task/project in the shared model and reopen the existing main window.

### Explicit task deletion (2026-09-27)

Deleting a task pauses it, blocks dispatch/edits/publishing/previews, cancels background naming and stops/awaits its agent and preview. Wait for any already-started publish/PR poll before touching the worktree. Run beforeRemove, then remove the owned worktree with `git worktree remove --force` only for explicit deletion. Automatic merged-worktree cleanup still refuses dirty worktrees. Cleanup failure leaves the task paused and available for retry. Never remove the user’s clone or delete branches/remote PRs.

Remove local messages, session, task-owned attachments/media/logs/proof, model preference and task records. Shared source attachments in project chat are retained. Remove references from dependent tasks and pause those tasks with an explanatory event; never silently unblock them. Proposal created-task IDs remain as historical references and acceptance stays idempotent, skipping deleted tasks. A persistent per-project task-number high-water mark, initialized from existing tasks, prevents deleted branch/worktree numbers being reused by either New Task or proposal creation.
