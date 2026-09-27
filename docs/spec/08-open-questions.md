# 08 · Open questions and spikes

Record findings inline (date, what was tested, result) and update the affected spec section.

## Spikes before milestone 2
1. **Codex app-server session lifecycle** (codex-cli ≥ 0.151): confirm `thread/start` → `turn/start` → continuation turns; `thread/resume` after the process restarts (context retained); `turn/steer` during an active turn; clean pause with `turn/interrupt`; token and rate-limit notifications; sandbox confined to the worktree with network on.
2. **Agent tools**: can dynamic tools (`DynamicToolSpec`, `item/tool/call`) be registered per thread in the current app-server, or must Build Mate use a per-session MCP server via the `config` override? Pick one and document the exact registration.
3. **Instructions updates mid-thread**: can `developerInstructions` change after `thread/start`? If not, use `thread/inject_items` or restart the thread with history.
4. **Video attachments**: does the selected model accept `localAudio`? If not, transcribe locally (Speech framework) and send text.
5. **TWG CLI for Bitbucket Cloud**: map every operation in 03 §3 to exact `twg` commands (Command Catalog), confirm JSON output, token setup UX (`twg setup bitbucket`), and rate limits. Where a command is missing, use the Bitbucket REST fallback with the same token.
6. **Recording**: choose the default approach: project-provided Playwright command (video on) versus agent-driven browser with capture by Build Mate. Measure reliability on one web project.

## Decisions
- **Decided (2026-09-26):** proof (recording, checks) is never added to PR descriptions; PR bodies contain only the change summary, with no Build Mate branding.

## Decisions to confirm with the owner
- Default "Agents at once" (spec: 4; designs show 10 as sample data).
- Branch naming convention (spec: `<number>-<slug>`, optional prefix).
- Retention for recordings and logs (spec: logs 14 days; recordings kept until the task is deleted).

## Known gaps in the designs
- Not drawn: Add Project, Hooks tab, list view, usage meter, paused banner, first-run, error states, changes sheet, larger recording player, Duo closed Backlog/Instructions. Build them from 04 and 06 in the same visual language.
- The Building composer placeholder says "It reads this on its next turn"; use "Message the agent" (agents receive steer messages immediately).
- The designs' "Studio · 4 building" host chip and Remote screen are v2.

## Milestone 1 findings — 2026-09-26

Manually tested against **codex-cli 0.151.0**, Xcode **27.0 (27A266a)**, on this Mac. Reproducible manual probes are in `scripts/spikes/`; these are deliberately excluded from the automated suite. The probes use disposable git repositories/worktrees and print no account/auth payloads.

- **Session lifecycle passed**: initialize → thread/start → two turn/start calls; a running sleep turn accepted turn/steer and answered `STEERED`; turn/interrupt reported `interrupted`; after terminating app-server and starting a fresh process, thread/resume retained marker `SPIKE-ORCHID-739`. Token-usage and rate-limit update notifications arrived; account/rateLimits/read returned populated limits.
- **Choose dynamic tools**: initialize with `capabilities.experimentalApi: true`; pass `dynamicTools: [{name, description, inputSchema}]` to thread/start. Codex issued item/tool/call; the client replied `{contentItems:[{type:"inputText",text:"…"}],success:true}`. The same tool remained available after a process restart and thread/resume, without re-registration. No MCP server, listener, helper or XPC is needed. The checked-in stable schema omits this experimental field; regenerate with `codex app-server generate-json-schema --experimental --out <scratch-dir>` to inspect it.
- **Sandbox passed with explicit turn policy**: workspaceWrite, writableRoots containing only the worktree, networkAccess true, excludeTmpdirEnvVar true, excludeSlashTmp true. An in-worktree write succeeded, a parent write failed with `operation not permitted`, and HTTPS returned 200. Using only thread/start's workspace-write default was insufficient for a temporary workspace: its sibling was writable. Always send the explicit policy on turn/start.
- **Instruction override limitation reproduced**: after a completed turn, restarting and passing a changed developerInstructions to thread/resume returned success but the model still followed the original suffix (`ORIGINAL`, not `UPDATED`). Do not rely on this override in 0.151. Use a fixed lifecycle developer brief directing the agent to the current instructions supplied in each turn's text. Regenerate these from SQLite on every turn; project instructions override global instructions. No history injection or new thread required. Active-turn instruction edits take effect at the next turn.
- **Model resolution**: omitting model selected an unusable local default in the permissions probe. model/list reported the account default; explicitly selecting that ID worked. Resolve the account default instead of hard-coding an ID. A stored explicit user model remains authoritative.
- **TWG unavailable**: `command -v twg` found nothing. No Bitbucket credentials were read or installed. Commands are catalog-confirmed only; exact REST methods/bodies are recorded in 03 §3. Authenticated output envelopes, flags, rate limiting and token transport remain to verify before milestone 5's Bitbucket provider.
- **Recording approach**: choose a project-provided Playwright command, with MP4/H.264 output at `$BUILD_MATE_RECORDING_PATH`. Three runs against a tiny local interactive web fixture succeeded (1.054 s, 0.521 s, 0.349 s; 2,889 bytes each) using installed Chrome and ffmpeg. Initial capture failed because Playwright's ffmpeg cache was absent; supplying the existing ffmpeg through an isolated temporary cache fixed it. This proves the mechanism, not reliability on a production web app. Playwright/ffmpeg belong to the project's hook toolchain, not app dependencies. Agent-driven capture remains a later lifecycle implementation choice.
- **Audio remains unverified**: no model/audio capability claim is made. Video ingestion is outside milestone 2; use a transcript plus localImage keyframes until tested in that milestone.

### TWG setup for the owner

Run interactively in Terminal (the installer opens Atlassian sign-in):

```sh
curl -fsSL --retry 2 https://teamwork-graph.atlassian.com/cli/install -o /tmp/twg-install.sh
bash /tmp/twg-install.sh
twg setup bitbucket
twg doctor
twg bitbucket repo get --help
twg bitbucket pull-requests create --help
```

Follow the Bitbucket token prompt; do not put the token in Build Mate, this repository or chat. If installation prints a PATH adjustment, apply it and open a new terminal. Then test a read against a disposable Bitbucket Cloud repository and validate create/retarget/merge there before enabling that provider.

Sources: [Codex app-server](https://developers.openai.com/codex/app-server), [TWG installation](https://developer.atlassian.com/platform/teamwork-graph/twg-cli/getting-started/installation/), [TWG catalog](https://developer.atlassian.com/platform/teamwork-graph/twg-cli/commands/commands-catalog/), [Bitbucket PR REST](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/), [commit statuses](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-commit-statuses/).

## Milestone 2 implementation assumptions

- The milestone's end-to-end demo drives the real Swift core through its public operations. The hostless test target compiles the same core files, places fake codex/gh/twg on an isolated PATH and uses a real local bare git remote. No internal application mocks or real host calls. The native launch screen is intentionally minimal; the designed workspace begins in milestone 3.
- The main-flow test needs a small lifecycle slice ahead of milestones 4/5: persisted questions/plan approval, independently executed checks/recording validation, human review, GitHub create/recover and merged-state polling. Complete UI, preview, stack rebasing, autonomous PR repair and merge remain in their specified later milestones.
- Core defaults remain four agents, two heavy steps, `<number>-<slug>`, logs retained for 14 days, media until task deletion. Nothing costly needs an owner decision now.
- A waiting question keeps its dynamic call pending while the process is alive. On app restart, resume the durable thread and provide all persisted answers in the next input. An unanswered question prevents dispatch. Turn-limit exhaustion pauses the task for human attention instead of spinning retries.
- Required recording without a configured command fails proof. Recording must be a playable video with positive duration no greater than 180 seconds. Failed proof returns to the agent; after three failures the core pauses it for attention. Rich Needs You presentation follows in milestone 4.

## Targeted Symphony audit — 2026-09-26

Completed before milestone 3; see [audit](09-symphony-audit.md). Fixed stale dispatch after awaited reconciliation, serialized pause handling, human-wait concurrency accounting, continuous-event timeout enforcement, configuration validation and escaped worktree-root symlinks. `afterRun` failure is now diagnostic only; it does not retry successful work. A live question/approval reserves an agent slot until answered or paused. These choices need no owner decision.

## Milestone 3 implementation decisions (2026-09-26)

- The shell includes a minimal New Task sheet (title/brief, Add to Backlog or Add to queue) and Move to Todo so a fresh installation has a usable path to its board. Attachments, project conversations/proposals, backlog ordering and instruction editing remain milestone 6. Question answers and plan approval reuse the existing core; full proof/review/preview UI remains milestone 4. Project chat and instructions show explicit unavailable/read-only states.
- Add Project accepts an existing local clone whose origin is GitHub or Bitbucket Cloud (HTTPS, SSH URL or SCP syntax). The default branch must exist locally because workspace creation branches from it. GitHub uses `gh auth status --hostname github.com` and `gh repo view <slug> --json nameWithOwner,defaultBranchRef`. If signed out, origin/HEAD supplies the branch and the project is added paused, with a copyable sign-in command. Missing `gh` instead offers its install command. Re-check after sign-in before adding, or resume the paused project after fixing sign-in externally.
- Bitbucket detection and local default-branch discovery work; authentication is explicitly **unverified**, task starts remain disabled and projects remain paused. No inferred TWG auth command or credential reader was added. Follow the spike setup above before milestone 5.
- App UI reads a consistent SQLite snapshot every 500 ms; this is sufficient for the small local v1 dataset and adds no event-routing layer. Selected task/project/page is saved under app storage in `selection.json`; navigation history is in memory. Standard native toolbar/sidebar layout takes precedence over the reference HTML's custom titlebar controls.
- `BUILD_MATE_DATA_ROOT` overrides app storage for isolated development/UI fixtures. `BUILD_MATE_APPEARANCE=light|dark` forces an appearance only for visual verification; normal launches follow macOS. Neither changes the process-boundary test design.
- Native XCTest automation currently fails **before executing the test**, with “Timed out while enabling automation mode” on this Mac's installed Xcode. The compiled UI scenario is in the optional `BuildMateUI` scheme. Normal `BuildMate` tests include a hostless process-boundary shell flow for discovery/auth, duplicate clones, task creation, transcript persistence, restoration, and disabled Bitbucket. Manual macOS accessibility inspection verified project setup, Backlog → Todo, question in Needs You, transcript, board/list, keyboard shortcuts and dark restoration. A follow-up pass verified Reduce Motion/Transparency behavior; spoken VoiceOver remains unverified. Exposed accessibility labels are not a claim of that full pass.

- Final verification: the normal five-test run passed once through `xcodebuild test`; subsequent invocations stalled in the host test coordinator before launching `xctest`. Running the final compiled bundle directly with `xcrun xctest .build/Build/Products/Debug/BuildMateTests.xctest` passed all five tests in 10.7 s. AGENTS.md records the build-for-testing/direct-run fallback. This does not unblock XCTest UI automation.

## Milestone 3 acceptance follow-up (2026-09-26)

- Simplest safe reading of incomplete proof setup: prevent dispatch when required recording has no nonblank command. Enforce it in New Task, Move to Todo, and the orchestrator so legacy Todo tasks cannot bypass the UI. Continue allowing Backlog. No additional setting or configuration UI was added.
- Composer copy follows actual delivery: live turn → Send message; no live turn → Save message for next run; unresolved question → Send answer. Queued messages never start/resume work. The core returns the delivery result for accurate confirmation.
- Added actionable missing-folder/non-git errors, Return to check a repository, and sidebar counts. Extended the existing shell flow to cover missing gh, blocked starts, legacy Todo dispatch, and saved delivery; the lifecycle flow verifies live steering. No extra unit-test suite.
- Light/dark inspection, keyboard setup/question/navigation, and Reduce Motion/Transparency checks are recorded in [10](10-milestone-3-acceptance.md). Temporary macOS preferences were restored. VoiceOver could be enabled, but the automation could not reliably inspect/control the reader (application inspection timed out); no spoken acceptance claim. Optional UI tests compile, but the previously observed Xcode automation-mode blocker remains.

## Design and motion pass (2026-09-26)

The request to refine the current shell does not expand later-milestone features. Use native inspector presentation and regular glass over scrolling content, rather than trying to reproduce the reference wallpaper's colour inside the app. This is a reversible design decision consistent with Apple's material guidance. No additional appearance preference or dependency was introduced. Detailed changes are in 06.


## Description-first task titles (2026-09-26)

User direction: titles should be generated from content and only optionally edited. Generate once on creation, not on each keystroke; a collapsed optional override keeps the brief primary. Save a locally shortened first sentence/line if Codex is unavailable, produces invalid output or exceeds the deadline. Existing tasks are not retroactively renamed. The task detail's pencil opens Rename Task; manual changes remain authoritative. A renamed task keeps its existing git branch and PR title.

Naming is an ephemeral read-only Codex request, independent of paused project execution. This means Add to Backlog can use Codex to name a task while still never dispatching its implementation. The real installed app-server accepted the output schema and returned “Compact verbose CLI output while preserving errors” for a longer CLI brief in 3.69 s. No tool items were emitted. No account/auth payloads were recorded. The automated suite continues to use fake processes only.


## Neutral project identity (2026-09-26)

User direction: represent projects with a folder, as in Codex, instead of a GitHub/Bitbucket logo. A project's visual identity must not imply a single repository or hosting service. This change is presentation only: current v1 project discovery and storage still require one local clone with a GitHub or Bitbucket Cloud origin. Multiple repositories, mixed-host projects and local-only repositories need separate functional scope; the neutral icon does not imply they are implemented.

## Task-specific proof (2026-09-26)

User direction supersedes the blanket recording gate above. Default to Automatic per task; the agent decides whether visual evidence is appropriate, takes brief instructions into account and explains the decision. Checks only and Checks + recording are explicit user overrides. At least one executable required check is needed, including a meaningful content/format check for documentation-only changes. All configured required checks remain enforced. Missing recording configuration no longer blocks dispatch; a missing or invalid task-required video blocks Human review and returns to the agent.

Project recording commands remain reusable defaults; the agent can supply a task command when none is configured. Existing tasks migrate to Automatic, existing proofs with videos retain their recording status, and the obsolete project-wide recordingRequired JSON field is ignored. Since durable Codex tools retain their original schema, old summary-only request_review calls can carry the structured proof report as JSON in summary. This avoids discarding existing Codex threads.

Agent-proposed commands use macOS sandbox-exec with writes confined to the worktree and task media directory, and network governed by the project setting. A manual local probe on this Mac confirmed allowed scratch writes and denial outside those roots. This is an OS command sandbox, not a helper process/service. Recording validation and review playback are separate; full playback/preview/editor UI remains milestone 4.

## Create new local projects (2026-09-26)

User direction: allow starting a project by specifying a folder and creating a Git repository. Simplest reading is local creation, without implicitly publishing anything. Accept a new folder under an existing parent or an existing empty folder, reject nested repositories and nonempty folders, initialise main and make an empty initial commit authored by Build Mate. Identity and signing overrides are per-command only; no global or repository identity setting is changed. No starter files are generated. Git metadata is the explicit user-requested exception to “do not write Build Mate files into the user's repository”; app data, workflow, logs and task worktrees still live under app storage.

Existing repositories without origin can also be added after their initial commit. Store host=local, use the folder name and current branch, and require no hosting CLI login. Local tasks run through proof to Human review; they are not called Merged and never implicitly push, publish or merge into the user's working copy. Publishing and local merge are separate follow-up scope. This supersedes the local-only limitation in the neutral-project-identity note above; multiple repositories per project remain outside this change.

## Editing existing tasks (2026-09-26)

User direction: tasks must be editable after creation. Replace the rename-only pencil with a visible Edit action, an Edit Task menu shortcut and board/list context actions. Allow title, brief and proof preference changes, preserving the selected project, branch and task identity. Cancel is draft-only; Save never generates a replacement title automatically.

Simplest safe behavior for scope changes after work starts: pause and await the existing worker, invalidate proof and plan approvals, supersede unanswered questions, and leave the task paused in Todo for a fresh plan on explicit Resume. Keep the thread and worktree so work is not lost. Backlog stays Backlog. Title-only edits do not pause or invalidate anything. Once a PR is opening/open or the task is terminal, only its title is editable; changing completed/published scope needs a new task. The core enforces these rules even if state changes while the editor is open.

## Merged workspace cleanup (2026-09-26)

Automatically remove clean worktrees after confirmed merge, with no live worker. Retain the local branch (and thus committed history), transcript and proof. A dirty worktree or failed beforeRemove hook is preserved, reported, and retried every minute, including after restart. Canceled and Human review tasks are unaffected.

## Queue ordering follow-up (2026-09-26)

Bring Backlog and Todo ordering forward. Persist contiguous descending ranks in a single transaction; retain task states and dependencies. Dragging changes priority only within the same project/state; cross-column movement is not implied. An already-running worker is never preempted.

Drag interaction refinement: preview the order in memory while hovering, and write ranks only on a valid drop. Escape or an outside drop cancels the preview. Use macOS 26 native SwiftUI drag-session callbacks and a lifted preview; do not use macOS 27-only reorder containers. The existing shell regression flow now covers preview isolation, refresh during dragging, cancellation, committed order and cross-state rejection. Pointer automation is not delivering native drags on this Mac; the fixture build is prepared for a manual row/card motion check, which remains pending.

## Usage UI brought forward (2026-09-26)

Read account limits even when no agents are running, using a short-lived app-server connection without thread/start or turn/start. Prefer the multi-bucket response; display all reported windows and highlight the most constrained Codex window. Poll once a minute and offer manual refresh. Usage is account-wide. Do not invent missing limits/reset times; preserve stale data with an error label. Only the informational UI is brought forward; no automatic usage hold is enabled yet. The initial decision to retain native sheet tint was superseded by the neutral-surface follow-up below.


## Neutral reference surfaces (2026-09-26)

The owner reversed the earlier tint decision and requested a closer reference match. Use reference light/dark surface colours for large app-owned backgrounds, including sheets, sidebar, inspector, board columns/cards and usage popover. This intentionally overrides the earlier system-background-only rule; system text, accents, controls, native presentation/motion and Liquid Glass on toolbar controls/composer remain. Use SwiftUI window/presentation backgrounds; do not change the user's desktop tint, wallpaper or accessibility settings.

## Immediate task creation and economical naming (2026-09-26)

User feedback: waiting for automatic naming is too slow, and naming must use a cheap model. Save/open with a local brief-derived title first; refine once asynchronously with an available Luna/mini model at its lowest supported effort. Never fall back to the expensive project/account default. Manual edits cancel refinement; failure, shutdown or unavailable models retain the saved title. Do not restart interrupted naming on app launch or rename existing tasks/branches/PRs. No new setting or API-key dependency.


## Conversation bubbles (2026-09-26)

User direction supersedes the reference’s unboxed agent text: show agent messages in the same speech-bubble treatment as human messages, aligned left versus right. Preserve speaker/time labels, selectable Markdown, chronological order, event rows and interactive question cards.

## Queue naming (2026-09-26)

User-directed rename: the ready-to-start state is displayed as **Queue** throughout the Mac app, including actions, help, accessibility labels and historical state-transition events. Keep the persisted `todo` state and tool enum unchanged so existing tasks and integrations remain compatible. Scheduling behavior is unchanged.

## Conversation bubble contrast (2026-09-26)

The owner supplied new light/dark chat references: agent bubbles are light grey in light mode and charcoal in dark mode; user bubbles are near-black in light mode and medium grey in dark mode, with white text. Apply these opaque neutral fills to the existing conversation layout; retain speaker/time, text selection, questions and event rows. This supersedes the earlier identical low-opacity grey fills.


## Milestone 4 lifecycle decisions (2026-09-26)

- Use agent-provided, optional `suggestedAnswer` for **Let the Agent Decide**. Show every proposed answer and require explicit confirmation. Legacy questions without suggestions stay answerable normally; never pick the first option on the user's behalf.
- Use the existing sandboxed proof command mechanism for recording and before/after screenshots, rather than add an embedded browser or a second recording service. The agent writes outputs to app-owned paths; Build Mate validates H.264/duration and decodable PNGs, independently runs checks, and records the commit SHA. This verifies executable results and media format, not whether the evidence adequately demonstrates the change.
- Review feedback through chat keeps the thread, branch and approved plan, saves the feedback, invalidates proof and resumes unless paused. Editing scope still requires a new plan. Existing proof without a SHA must be refreshed before publishing. Three failed proof attempts pause for human attention; Resume resets that consecutive-failure allowance.
- Preview “idle” means 30 minutes since Run/Open Preview in Build Mate. External browser activity is not observable. Each starting/running preview holds one of two preview slots; Stop frees it immediately. Preview slots are independent of verification capacity so an open preview cannot starve proof. Preview commands are explicit per-project configuration and must use the supplied port and local bind address; no automatic dependency installation. CLI/native tasks use Terminal/editor instead of HTTP preview.
- Preview output is redacted, capped to the latest 64,000 characters in memory, and available while the preview/status exists. Preview processes are ephemeral and are not restored after app restart.
- Full Settings remains milestone 7; New Task exposes the per-task plan approval override now. Full SCM/stacking/watch/merge remains milestone 5.


## Editor menu icon rendering (2026-09-27)

The installed macOS 27 SDK documents that menu images are normally hidden unless `NSMenuItem.preferredImageVisibility` is visible. SwiftUI exposes no equivalent modifier in this SDK. Use a small `NSComboButton` representable with native `NSMenu` rows, 16 pt intrinsic `NSImage` sizes and a guarded macOS 27 image-visibility override. This is a concrete AppKit exception, not a custom-drawn menu. Keep the original Default Editor submenu as requested.

### Review feedback through chat (2026-09-27)

Per user direction, remove the separate Send Back button, sheet and menu command. Any non-empty chat message in Awaiting human review resumes the existing task through Building and invalidates old proof. This simplest reading avoids a second model call to classify questions versus change requests; even a review question reopens the conversation and requires fresh proof before publication. Existing pause flags remain authoritative. Other inactive states continue to save messages without dispatching.

Review verification exposed a runtime abort in `_AVKit_SwiftUI` superclass metadata when a recording is displayed on this Mac. Use native `AVPlayerView` with inline controls in a small SwiftUI representable; retain the existing player lifetime and expanded recording window. This is a concrete compatibility exception to SwiftUI first.


### Project chat sequencing (2026-09-27)

User requested project chat now. No milestone-5 dependency blocks text conversations, task proposals, mixed Queue/Backlog routing or backlog refinement. Bring those forward while keeping instruction editing and media attachments as the rest of milestone 6. Keep one durable thread per project and a separate read-only default-branch worktree in app storage. Refresh from the local default branch, avoiding surprise network fetches. Chat shares agent slots and project/global pause; user messages queue while paused. One response at a time, with Stop/Retry, is simpler than concurrent steering and proposal mutations.

Use zero-based dependency and selection indices in project tool contracts. If a selected task depends on an unselected task, reject the selection with an explanation instead of silently removing the dependency. Natural-language mixed routing passes an existing proposal ID and queue indices; Backlog is the default for remaining selected items. Proposal acceptance and persisted created IDs form one transaction. Repeat acceptance returns existing tasks. Same-input identical proposals reuse their saved identity. Project question data lives in message payloads; explicitly decode those JSON envelopes from SQLite rather than mistaking stored JSON text for a JSON string value.


## Screenshot attachments and retention (2026-09-27)

- Interpret “draw a location” as dragging a capture rectangle, using `/usr/sbin/screencapture -i -s`; window capture uses `-i -w`. Both write PNG directly to an app-owned draft location. No custom screen overlay or helper daemon.
- Arbitrary regular files may be attached; images are actual Codex `localImage` inputs, other file types are readable local references. Do not claim video understanding through extracted frames/audio yet.
- User clarified that project-chat references should follow created tasks. Copy the conversation's attachments into created tasks and track source IDs. Delete bytes after all linked tasks merge; retain history/filenames. Unassigned files stay with the project. A proposed 30-day policy was rejected by approval review and is not implemented.

## Milestone 6 completion pass (2026-09-27)

- Project and global instructions autosave after one second, flush when leaving the editor, and apply on the next turn of retained task/project threads. Repository AGENTS.md remains owned by the repository; the app only offers Open.
- New Task now accepts the same files, screenshots and clipboard images as chat. Import and task creation are atomic. Video attachments supply six evenly spaced, orientation-correct frames; the original remains available to the agent and Quick Look. Audio is explicitly labelled as not transcribed: no speech permission or audio-model capability is assumed. Automatic audio transcription remains an open integration question, not a claimed capability.
- User corrected the requested sequence to milestones 6 then 7. There is no milestone 8.

## Milestone 7 controls (2026-09-27)

- Default usage hold: below 15% in the limiting Codex account window. Zero disables it. Initial startup reads usage before dispatch; unknown usage does not count as zero. A failed refresh preserves the last known hold rather than silently spending more. Account polling remains every 60 seconds, with live task rate-limit events also applied. Holds affect new task attempts and project-chat responses, never interrupt an active turn. Resume Anyway lasts until usage recovers above the threshold or the app restarts.
- Settings exposes implemented controls only. PRs are currently opened explicitly by the user and automatic merging awaits milestone 5; no nonfunctional merge toggle is presented. No PR footer/proof toggles are provided because they conflict with the v1 requirement for unbranded, summary-only PR bodies.
- Hook editing is unlocked after an explicit in-app confirmation per settings session. Settings apply immediately; incomplete check rows are retained as drafts until both name and command are present. Instruction edits apply next turn, without replacing the Codex thread.
- Native notifications are opt-in from Settings, respect system Focus, group by project and offer Open. Per-question, approval, proof and retry IDs are persisted in app storage to avoid redelivery on refresh/restart. Inline notification answers/approvals are omitted; the corresponding native app view handles them with current state.
- Main workspace is a single Window. Its observation/scheduler lifetime belongs to the app, so the menu-bar panel and notifications continue after the window closes. Quit with active agents asks before orderly shutdown; worktrees and Codex threads remain durable.

### Per-conversation model selection (2026-09-27)

User requested model and effort editing at any time for tasks and project chat, with Astra High as the project-chat default. Interpret “at any time” as saving immediately for the next turn; do not interrupt or replace an active conversation. The local protocol schema and [official app-server documentation](https://learn.chatgpt.com/docs/app-server) support model/effort overrides on `turn/start`, not `turn/steer`. Store choices separately from lifecycle records to prevent stale task/project saves from erasing them. Existing task defaults and economical title generation remain unchanged.

Read-only manual `model/list` probe against installed codex-cli 0.151.0 returned `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, and `gpt-5.5`. Including hidden models additionally returned `gpt-reserve` and `codex-auto-review`; Astra was absent. No inference or account mutation was performed. Do not infer CLI model availability from the Codex desktop picker. Preserve the requested Astra High default and report unavailable selection explicitly until the installed CLI/account offers it or the user chooses another model.

### Compact project-chat inspector (2026-09-27)

The later explicit request to order the list most recent first supersedes the initial interpretation of “just show the last” as one task. Show all chat-created tasks ordered by creation time descending, with task number descending as the tie-breaker. Keep Project information and Open Tasks in a separate fixed bottom section, outside the task scroll area.

### Deleting active tasks (2026-09-27)

The user explicitly requests deletion even during work. Treat confirmed deletion as authorization to discard unfinished changes in that task’s app-owned worktree. Retain Git branches and hosted PRs; pause dependent tasks and remove their deleted dependency/stack references, requiring deliberate review/resume. A failed cleanup hook or Git removal leaves the task paused for retry. This extends the previous core delete operation, which required manual pause and refused dirty worktrees.

## Linked-worktree Git permissions — 2026-09-27

A real task exposed a gap in the milestone 1 sandbox spike: it tested source writes, but not staging or committing. Codex protects `.git` and linked Git directories; a worktree-only writable root plus `approvalPolicy: never` prevented the required commit. The old fake agent committed outside any command sandbox and therefore missed this.

Keep `workspaceWrite` and explicit temp exclusions. On every task turn, including resumed threads, resolve and validate the assigned worktree’s Git paths and explicitly allow its private metadata directory, the common objects directory, and only its branch ref/reflog and associated lock files. Do not grant the entire common Git directory or change permissions on disk. Shared object writes are necessary for commits; config, hooks, other refs, the main checkout and sibling worktree indexes remain protected. Git’s optional automatic shared-ref maintenance may be denied; this does not prevent the task commit. Project chat and proof-command policies are unchanged.

Manually verified with **codex-cli 0.157.1**, using real app-server `command/exec` (no model inference) in `scripts/spikes/codex_git_permissions.py`: the previous policy denied `git add`; scoped grants allowed add and commit; writes to the main checkout, shared config/hooks and main branch ref were denied. Both checkouts were clean afterward and main retained its initial commit. The existing lifecycle test now runs the fake agent’s Git writes through Seatbelt using the actual roots supplied by Build Mate, including resumed review turns; it also attempts forbidden clone/config/hooks/main-ref writes. This preserves the process-boundary stub rule while the manual probe checks Codex’s own enforcement. Existing sessions receive a fresh permission policy and retry guidance on their next turn; no conversation or worktree reset is needed.

## Queue-only task creation — 2026-09-27

User direction removes Backlog entirely. Manual creation and project-chat creation/acceptance always save to Queue. Unfinished ideas remain in the conversation or unaccepted proposals; there is no replacement draft-task state. Pause controls, dependencies, usage and agent-slot limits still gate dispatch. Unsupported host projects can save queued tasks, but their existing run restriction still prevents dispatch.

Migration v8 appends legacy backlog tasks after the existing queue, preserving each group's priority order and all task content, dependencies, attachments, conversations and pause flags. The Backlog enum, navigation entry, creation choices, move actions and selection toolbar are removed. Saved Backlog navigation falls back to Tasks. Shortcuts become Chat ⌘2, Tasks ⌘3 and Instructions ⌘4. The original design exports and earlier milestone notes are historical where they show Backlog.

Project chat receives current workflow instructions every turn. Old durable tool schemas can still send queueIndexes, but all selected tasks are queued regardless of that legacy field. Proposal dependency validation and idempotent acceptance remain. Refinement uses the normal task scope-edit operation: unstarted tasks remain queued, started work pauses for replanning, and published/terminal tasks cannot change scope. This replaces the old Backlog-only refinement path.

Validation: extend the existing shell/project-chat lifecycle scenarios for queue-only creation, old tool arguments, dependencies and pause controls; add one migration regression covering priority order, pause, content, attachments, conversation and a second open. The migration uses UUID database values because GRDB persists task/project IDs as blobs despite SQLite's TEXT column declaration.

The optional native UI scenario now uses the single Add to queue action and Tasks ⌘3. Offscreen SwiftUI captures show the simplified action layout, but native editor/material rendering is incomplete in that renderer; this is not a full light/dark interaction or spoken VoiceOver sign-off. The previously recorded native automation-host limitation remains.

## Screenshot review controls — 2026-09-27

The screenshot sheet now offers Open in Preview and native full-screen expansion. SwiftUI owns the separate screenshot window; a small AppKit view requests full screen when that window becomes key and closes it when full screen ends. Native transitions, Preview launching, keyboard interaction and spoken VoiceOver still need manual verification because the UI automation/access limitation above remains. Build and the existing process-boundary regression suite are the automated checks for this change.

## UX review implementation — 2026-09-27

The owner approved all recommendations in `docs/design/ux-review-2026-09-27.md`. This supersedes earlier presentation notes that describe an always-open inspector, a lifecycle checklist, all chat-created tasks at once, per-message speaker labels, repeated state events, heavy-step settings or a user-maintained turn budget.

- Preserve the actual task state machine. Planning and Testing still need defined transitions; do not infer stages from tool activity. Show the current state and a useful waiting reason instead of the misleading checklist.
- Start with details closed, then remember the choice. Remember brief disclosure, board/list choice and project expansion in app-owned `view-preferences.json`. Unsent drafts and per-collection searches survive navigation within the app; they are not promised to survive a restart.
- Show the five newest chat-created tasks. View All Tasks opens the existing project collection; it does not introduce another filter or expandable archive. Keep compact Project information pinned below the scroll area.
- Keep internal proof/preview capacity and existing security controls. Remove the lifetime turn limit. Existing turn/read/stall timeouts remain; three consecutive tool-free task turns or three failed attempts pause for a human decision. Automatic recovery before that threshold stays out of Needs You. Explicit resume resets failure recovery.
- Background issues belong to their task/project or the global scheduler. Dismissal suppresses the same issue until it changes or succeeds; success clears stale issues. Do not show one project’s error on another project’s screen.
- SwiftUI owns native toolbar grouping, inspector transitions and controls. Use consistent composer spacing, content-sized Markdown bubbles and Reduce Motion-aware movement rather than new appearance preferences.

Static offscreen SwiftUI rendering can verify text wrapping and component geometry. It cannot establish native toolbar/material rendering, live drag smoothness, keyboard focus or spoken VoiceOver acceptance. The previously denied preview-app automation access was not bypassed.

## Internal workload limits — 2026-09-27

The owner reaffirmed removing the fixed turn ceiling and heavy-step Settings control, while retaining sensible resource protection. The UX change already removed those controls and the lifetime ceiling. Keep Agents at once as the visible scheduling preference. Verification jobs retain their internal default of two (legacy stored capacity is preserved), and previews have an independent fixed limit of two. Previously two long-running previews could occupy every shared slot and starve a task’s proof until one closed; that coupling is removed. Do not silently terminate a preview to start verification, or introduce another user setting or speculative CPU/RAM controller. These are app-wide simultaneous-job limits, not limits on how many checks a task can perform.

Codex owns its model/tool loop and subagent orchestration. Its [documented concurrency limit](https://learn.chatgpt.com/docs/config-file/config-reference) concerns spawned-agent threads; it is not a documented adaptive scheduler for Build Mate’s independently launched checks and preview processes. At this workload-limit checkpoint, child-agent event routing and display were still a separate integration gap. The native subagent implementation and verification below address that gap.

## Native Codex subagent protocol spike — 2026-09-27

Manually inspected the experimental JSON schema generated by installed **codex-cli 0.157.1** and exercised real app-server parent/child conversations in isolated temporary directories. These were bounded compatibility probes, outside the automated suite: one child returned a fixed result through a harmless dynamic tool; a follow-up reused that child; a final child ran only `/bin/sleep 30` to investigate cancellation. No project files or user configuration were changed. Probe threads were archived and every recorded probe process was subsequently absent.

The [official subagent documentation](https://learn.chatgpt.com/docs/agent-configuration/subagents) describes Codex-owned spawning, messaging, waiting and inherited permissions. Runtime `thread/start` and `thread/resume` overrides with `config: {"agents.enabled": true}` worked; the obsolete `features.multi_agent` switch was unnecessary. Build Mate should enable native delegation for task/project conversations through their runtime configuration and instructions, retain Codex's default child concurrency, and leave title generation unchanged. This requires no user-maintained feature flag or new setting.

Verified event contract:

- The generated item type is `collabAgentToolCall`, with `tool`, `status`, `senderThreadId`, `receiverThreadIds` and `agentsStates`; optional fields include `prompt`, `model` and `reasoningEffort`. Call statuses are `inProgress`, `completed`, `failed` and `interrupted`. Agent states include `pendingInit`, `running`, `interrupted`, `completed`, `errored`, `shutdown` and `notFound`.
- Actual native spawning emitted parent `subAgentActivity` items containing `id`, `agentPath`, `agentThreadId` and `kind`. Kinds are `started`, `interacted`, `interrupted` and `completed`. Both `item/started` and `item/completed` carried the activity. The observed `collabAgentToolCall` wait items had empty receiver lists and empty agent-state maps, so those maps alone cannot discover or track children.
- No child `thread/started` notification appeared. Child `thread/status/changed`, `turn/started`, message deltas/completions, token updates and `turn/completed` arrived automatically on the parent's existing connection, without a child subscribe or resume call. Discover from `subAgentActivity.agentThreadId`, then route by thread ID so child messages, usage and tools cannot mutate the parent conversation accidentally.
- A parent `subAgentActivity(kind: completed)` arrived before the child's `turn/completed`. Repeated started/interacted activity must not revive an already completed child, and activity completion must not prematurely clear a known active turn. Direct child turn events establish the turn lifetime.
- Children inherited the parent's dynamic tools. The harmless tool request arrived with the child's `threadId` and `turnId`. Build Mate must explicitly reject child calls to parent-owned task/project lifecycle tools; hiding controls in the inspector does not enforce that boundary.

`thread/read` metadata exposed `parentThreadId`, `agentNickname`, `agentRole`, `model` and `reasoningEffort`. Its `source.subAgent.thread_spawn` object contained `parent_thread_id`, `depth`, `agent_path`, `agent_nickname` and `agent_role`. Use the meaningful agent path when available. In the observed child, `preview` was empty and `name` was null; completed child history contained the dynamic-tool call and response but no initial user-message prompt. Do not fabricate a prompt from the nickname or a parent wait item. `includeTurns: true` also returned a live `inProgress` child turn; its items were still empty while the sleep command ran. Preserve event-derived status when supplementing metadata. The [app-server documentation](https://learn.chatgpt.com/docs/app-server) and locally generated `ServerNotification.json` / `v2/ThreadReadResponse.json` were the protocol references.

Cancellation was only partly verified. Interrupting the parent completed its turn as `interrupted` while the child remained active; answering the child's held dynamic-tool request then let it finish normally. The sleep probe likewise showed the child command still alive after parent interruption. **Parent `turn/interrupt` does not cancel descendants.** Native command/code-mode processes also had process-group IDs different from the app-server's group. Sending SIGTERM to the app-server group succeeded, but the probe's subsequent group-existence check raised `EPERM`, aborting immediate descendant verification. A fresh app-server later read that child turn as `interrupted`, and all recorded PIDs were absent at cleanup, but the command's 30-second bound means this does not prove prompt shell cancellation. Do not claim that signalling the server group alone has verified immediate cleanup of native child shell processes; descendant shutdown remains an integration check. Automated process-boundary fixtures must cover active children and detached command groups without invoking real Codex.

A final targeted probe used a new isolated child running only `/bin/sleep 15`. After interrupting the parent, directly interrupting the active child turn produced child `turn/completed(status: interrupted)` and an idle thread. However, the sleep PID remained present in `ps` after 4.182 seconds while the app-server was still running. That check recorded PID/parent/group/command, not the process state, so it cannot distinguish a running command from an unreaped zombie; it does not verify prompt command cleanup. Both threads were archived, the server was closed, and cleanup targeted only the recorded sleep PID if it remained; the recorded server and sleep PIDs were subsequently absent. Explicit child-turn interruption correctly updates the agent lifecycle, but should not be presented as independently verified termination of every child command.


## Codex runtime efficiency audit — 2026-09-27

The owner requested investigation of quality, latency and token overhead relative to Codex desktop. See [the runtime audit](../codex-runtime-audit.md) for source findings, runtime metadata and deliberate boundaries. Match native thread semantics: durable history is already in Codex, so app-side replay is unnecessary. Track accepted inputs per thread while retaining pending messages/answers after failed delivery; bootstrap legacy delivery records once because past steering acknowledgements were not stored. This may replay legacy input once rather than risk silently dropping it.

Use installed CLI settings/capabilities, preserving explicit model/effort selections and Astra High for project chat. Do not silently launch a private desktop-bundled executable, disable sandboxing or automatically approve native permission requests to claim parity. Independent proof, project-chat read-only scope and app-owned lifecycle gates remain product requirements. Same model and effort alone do not guarantee identical answers, speed or token counts; no controlled output/performance benchmark was run.

## TWG 1.3.1 command contract — 2026-09-27

The official release download was fetched to a temporary location for CLI inspection (not installed into PATH). Its SHA-256 matched the official SHA256SUMS-v1.3.1 entry for twg-darwin-arm64-v1.3.1: `07c08244dd7e435809f9356f69a645e47b643e78024eb774c902bdad3df0a1ac`. `--version` and the native Bitbucket subcommand help ran successfully. Create/update accept `--description-file`; update supports `--dest`; merge accepts `--pull-request`, `--merge-strategy`, and asynchronous status is queried separately. Pipeline get supports logs/test reports and rerun-failed exists. Importantly, generic `twg api` explicitly excludes Bitbucket authentication, so it cannot be used as the previously proposed REST fallback. No credentials were read and no host mutations were performed. Authenticated output and repository policies still require a disposable Bitbucket repository.

- 2026-09-27: Authenticated Bitbucket verification is deferred at the user's request; focus hosted-workflow testing on GitHub. `twg` help was verified, but no successful Bitbucket authentication or mutation is claimed.
- Delivery sizing assumption: split/combine preserves unpublished source branches rather than rewriting them automatically. Replacement agents inspect and reuse relevant implementation; published tasks are revised on their existing PR to preserve review continuity.
