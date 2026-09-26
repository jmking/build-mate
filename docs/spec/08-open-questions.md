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
- Not drawn: Add Project, Hooks tab, list view, usage meter, paused banner, first-run, error states, changes sheet, larger recording player, Send Back sheet, Duo closed Backlog/Instructions. Build them from 04 and 06 in the same visual language.
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

- The shell includes a minimal New Task sheet (title/brief, Add to Backlog or Start Now) and Move to Todo so a fresh installation has a usable path to its board. Attachments, project conversations/proposals, backlog ordering and instruction editing remain milestone 6. Question answers and plan approval reuse the existing core; full proof/review/preview UI remains milestone 4. Project chat and instructions show explicit unavailable/read-only states.
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
