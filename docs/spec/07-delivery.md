# 07 · Delivery

## Versions
| Version | Scope |
|---|---|
| **v1 — Mac** | Single app process; local Git projects plus projects on **GitHub and Bitbucket Cloud**; Codex app-server runner; built-in tracker; Needs You; project chat with proposals; board (+ list view); New Task; task views for every state; clarification questions; plan/PR/merge approvals; proof of work (checks + recording); Run locally previews; Open in editor/Terminal/Finder; stacked PRs; PR watch mode; pause (task/project/all); project and global instructions; Settings (General, Hooks, Instructions); menu bar extra; notifications; usage meter and hold; light and dark mode. |
| **v1.1** | Ship as one PR (feature branch); `<n>.localhost` preview proxy; list-view polish. |
| **v2 — Remote** | Settings › Remote, device pairing, private-network API, CloudKit push, iPhone Pro app, iPhone Duo layouts. |
| **v3** | Claude agent runner; Linear/Jira tracker adapters; Export to repository (`WORKFLOW.md`). |

## Milestones (v1)
Each milestone ends with a demo and its acceptance criteria passing.

1. **Spikes** (08): Codex app-server session lifecycle incl. `thread/resume`, `turn/steer`, `turn/interrupt`, tool mechanism; TWG CLI Bitbucket command mapping; recording approach.
2. **Core**: storage, data model, orchestrator loop, worktrees, hooks, Codex runner, retries, reconciliation, plus the e2e test harness (fake `codex`, `gh`, `twg` executables on `PATH` and a local bare git remote; see `AGENTS.md`).
3. **App shell**: window, sidebar, projects (Add Project), Needs You skeleton, task view transcript, board.
4. **Lifecycle**: questions, plan approval, proof runner, human review, previews, open-in-editor.
5. **PRs**: SCM providers (GitHub, Bitbucket), open PR, stacking, watch mode, merge rules.
6. **Project chat**: project agent, proposals, Queue, New Task, instructions.
7. **Controls and polish**: pause, menu bar extra, notifications, usage meter, Settings, dark mode, accessibility, keyboard, empty and error states.

## Acceptance criteria (v1)
Test in light and dark mode; with VoiceOver; keyboard only; Reduce Transparency and Reduce Motion on.

**Projects and storage**
- Rename a project from Project Settings, the Project menu or its sidebar context menu. The display name persists across relaunch, accepts spaces/Unicode and leaves repository paths, tasks and conversations unchanged. Blank names cannot be saved.
- Create New initialises a new or empty local folder on main, seeds an empty commit and adds it as a local project. Reject nonempty and nested-repository folders; no remote is created. Local tasks run in app storage and stop at Human review until publishing/local merge support is added.
- Project Settings supports adding/removing multiple Git repository folders. Each task targets one linked repository; project chat can coordinate dependent tasks across repositories. Worktrees, permissions, PRs and cleanup use that task’s repository. Upgrades preserve existing task targets; unlinking keeps the clone and is blocked while unfinished work or retained task worktrees exist.
- Adding a project from a local clone detects GitHub or Bitbucket Cloud, remote slug and default branch, and shows CLI sign-in status with a fix action.
- After a full task lifecycle, `git status` in the user's clone shows no new or modified files, and no files exist in the repo that Build Mate created.
- Removing a project deletes its data and worktrees and leaves the clone untouched.

**Project chat and task creation**
- Describing work produces a proposal card; **Add N to Queue** creates the selected tasks with dependencies. All manually or agent-created tasks enter Queue.
- Unselected ideas remain in the conversation/proposal. No task is created until the user accepts a proposal or explicitly requests creation.
- Queue dispatches in rank order when a slot is free, respecting dependency, pause and usage gates. Legacy backlog tasks migrate after existing queued tasks without losing content or pause settings.
- Refine with Agent updates the description and any questions appear in the chat.

**Lifecycle**
- A task whose agent asks a blocking question moves to Needs Clarification, appears in Needs You, and resumes within 5 s of the last answer, with the same Codex thread (context retained).
- With "Ask me before starting to build" on (project or task), the task waits in Queue with an Approval in Needs You; Approve Plan starts building.
- A task cannot enter Human review until required checks pass and any task-required recording exists; failed proof returns to the agent with the failure.
- Run locally starts the preview on a unique port and opens the browser within 90 s, for two tasks at once without port clashes.
- Open Pull Request creates the PR on the right host; dependent tasks create stacked PRs targeting the base task's branch; after the base merges, the dependent PR is rebased and retargeted to the default branch automatically.
- In PR, a failing required check triggers the agent to fix and push without user action; a decision question appears under Decisions in PR.
- With "Ask me before merging" off, the agent merges (squash, delete branch) only when required checks and approvals pass; it never uses admin bypass.

**Control**
- Pause task stops the session after the current step within 30 s, keeps the worktree, and Resume continues the same thread.
- Pause Project and Pause All stop dispatch and pause running tasks; the sidebar and menu bar show paused state; Needs You still updates.
- Usage below the hold threshold stops new dispatch and shows "Waiting for usage" on Queue cards.

**UI**
- Every screen matches its design in `docs/design/png` in both appearances (layout, hierarchy, copy), built with native controls.
- Every action is reachable from the menu bar and has the shortcut in 04 §14.
- The menu bar extra shows Needs You and Building items and opens tasks in the main window.
- Notifications arrive for each new Needs You item and deep-link to it.

## Milestones 1–2 handoff (2026-09-26)

- **1 demo:** real Codex 0.151 thread/turn/steer/interrupt/restart-resume and persistent dynamic tools passed. Explicit worktree-only write policy plus networking passed. Three local Playwright recording attempts passed after resolving its ffmpeg prerequisite. TWG was not installed; the documented setup/REST mapping is the allowed GitHub-first fallback, not an authenticated Bitbucket verification. See 08.
- **2 demo:** three process-boundary e2e tests cover the lifecycle through host merge, scheduler rank/dependency/pause/crash/stall behavior, and failed/timed-out hooks. One state-machine unit test checks every state pair plus proof/question/plan/dependency/merge guards. The user clone stays clean; data and worktrees stay beneath app storage.
- The native startup screen launches and exposes its text to accessibility. Full designed light/dark screens, keyboard flows, VoiceOver operation, Reduce Motion and Reduce Transparency acceptance belong to milestones 3–7 and have not been claimed complete here.

> Historical implementation notes below may describe superseded UI. The Queue-only change removes Backlog, all routing choices and the separate view; current acceptance criteria above and Mac UX are authoritative.

## Milestone 3 handoff (2026-09-26)

- **Demo:** launch → Add Project → Check Repository → Add Project → ⌘N → Add to Backlog → Move to Queue → ⌘4. The board reflects durable task state; a blocking question appears in Needs You and opens the persisted transcript. ⌘L toggles board/list, ⌘1–5 navigate, ⌘[/⌘] move through history, ⌥⌘I toggles the inspector, and ⌥⌘P pauses/resumes dispatch. Relaunch restores the selected task. Light/dark task and board layouts were inspected in the running app.
- Native shell implementation is delivered. Five automated tests pass (four process-boundary flows and the transition-rule unit test). Optional XCTest UI automation is compiled but blocked by the host's automation-mode initialization timeout; see 08. The follow-up acceptance pass checked keyboard flows and both system Reduce Motion/Transparency settings. Spoken VoiceOver verification remains blocked, so full accessibility acceptance is not claimed complete. See [acceptance record](10-milestone-3-acceptance.md).
- Scope still pending: review/playback/previews/editor actions (4), full SCM/PR controls (5), project chat/attachments/backlog ordering/instruction editing (6), usage/settings/menu bar/notifications/final accessibility polish (7). Board drag/drop is deferred with backlog ordering. No v2/v3 features were added.

- Follow-up demo: an unconfigured project can save to Backlog but cannot start; a configured fixture answers a question and restores its transcript after relaunch. The composer explicitly confirms whether a message was sent or saved without starting work.

## Task-specific proof follow-up (2026-09-26)

User-directed scope change ahead of the rest of milestone 4: remove the project-wide recording start gate. Automatic task proof selects evidence suited to the work, with user overrides. The app independently executes checks and validates required recordings before Human review. Playback, previews, editor actions and complete review controls still belong to milestone 4. The earlier unconfigured-project handoff describes the superseded behavior.

## New local projects follow-up (2026-09-26)

User-directed extension to project setup: Add Existing or Create New. A new project needs no hosting account and can run its first task in an isolated worktree. Remote creation/publishing and local merge are not included. Multi-repository project links were subsequently added at the user’s request (see Projects and storage acceptance criteria). The generic folder icon now also represents local projects.

## Queue, cleanup and usage follow-up (2026-09-26)

User-directed additions: remove clean worktrees after confirmed merge (retain task/history/proof/branch; preserve dirty worktrees), reorder Backlog and Queue within each project using drag-and-drop or Move Earlier/Later, and show account usage windows/reset times in the sidebar and popover. Automatic usage holds/settings and menu-bar usage remain milestone 7; this usage UI is informational. Native sheet materials are retained.


## Milestone 4 handoff (2026-09-27)

- **Implemented:** explicit suggested-answer confirmation; per-task plan approval at creation; complete proof review with check logs, H.264 playback/expanded player, before/after PNGs and per-file changes; chat review feedback with fresh-proof enforcement; local preview configuration/start/reuse/Stop/error output, unique ports, shared heavy-step limit, idle/quit cleanup; installed editor/Terminal/Finder actions and shortcuts. Existing basic GitHub publication remains available; the full SCM milestone is next.
- **Demo:** create a task with Ask me before building → answer its question (or confirm its suggestions) → Approve Plan → inspect proof in Awaiting human review → expand the recording/check logs/Changes → configure Run locally once and open the preview → Stop → send feedback in chat → review fresh proof. ⌘O opens its code, ⌃⌘T opens Terminal, ⌥⌘R opens Finder.
- **Automated validation:** nine tests pass in about 33 seconds (eight process-boundary end-to-end flows and the transition-rule unit test). The native app and optional UI test target both compile. Lifecycle now covers suggested answers, task-level plan gating, invalidation after scope edits/chat review feedback, retained thread, stale-commit PR rejection, three-failure pause/resume, visual versus functional proof and clone cleanliness. Preview flow covers two concurrent worktrees, repeated requests, unique ports, slot exhaustion, timeout/failed startup, cancellation and quit cleanup.
- **Acceptance limitation:** this milestone's new light/dark screens, playback interaction, keyboard-only and spoken VoiceOver pass still require an unlocked Mac. Computer use reported the Mac locked; an unlock request is pending. Build/tests establish core behavior, not full visual/accessibility acceptance. Prior UI automation host initialization problems remain documented in 08. Do not mark those checks as passed.
- **Commands on this Mac:** `xcodegen generate`; `xcodebuild -scheme BuildMate -destination 'platform=macOS' -derivedDataPath .build build-for-testing`; `xcrun xctest .build/Build/Products/Debug/BuildMateTests.xctest`; `open '.build/Build/Products/Debug/Build Mate.app'`. The hostless runner avoids the previously documented Xcode automation-mode timeout; it still runs the real Swift Testing suite.


## Project chat brought forward (2026-09-27)

- **Scope:** persistent project-agent text chat, read-only project checkout, proposals/dependencies, selective Backlog/Queue creation, mixed routing through chat, inline questions in chat/Needs You, live created-task inspector, backlog refinement, Stop/Retry and restart-resume. Shares agent concurrency and pause controls. Milestone 5 is still outstanding; attachments and instruction editing remain the rest of milestone 6.
- **Demo:** select Chat → describe work → inspect/select a proposal → Add to Backlog → open a created task from the inspector → Refine with Agent. A message such as “start the first two now, backlog the rest” routes the proposal accordingly. Restart preserves the conversation and proposal state.
- **Validation:** all ten tests pass in about 41 seconds; the project chat flow takes about 8 seconds. One added process-boundary end-to-end test covers proposal idempotency/dependencies/project boundaries, questions, Needs You, mixed destinations, refinement, read-only clone safety, pause and same-thread recovery from process failure. Light/dark UI and keyboard send/proposal actions checked in a separate fake-CLI fixture. Spoken VoiceOver acceptance remains unverified.


## Screenshot/file attachment follow-up (2026-09-27)

- Both chats: window/area screenshot capture, file picker, file/image drag-and-drop, removable draft previews, attachment-only messages, native Quick Look and image thumbnails.
- Delivery includes image inputs to Codex, persisted file references, proposal-to-task inheritance and merge-based cleanup with shared-source protection. Video frame extraction and instruction editing remain outstanding.
- Process-boundary lifecycle tests now verify image delivery on live steering, persistence after the source is removed, copied task references, corrupt-image rollback, cleanup after merge/restart, and keeping shared chat sources until every linked task merges.
- Demo: camera → Capture Area → draw a rectangle → preview/remove or send; paperclip → select an image/file → send → accept a task proposal. The task receives the attachments and keeps them until merged.
- Validation: all ten tests pass in about 41 seconds. Native picker, attachment-only sending, persisted transcript images, capture menu labels and light/dark layouts were checked in an isolated fake-CLI preview. The macOS capture overlay could not be driven through automation; a manual capture check is pending. End-to-end pointer drag/drop, Quick Look interaction and spoken VoiceOver remain unverified; do not infer full acceptance from the build or accessibility tree.

## Milestone 6 completion pass (2026-09-27)

- Project/global instruction editors now autosave, preserve repository files and update resumed agent turns. New Task supports attachments; both composers support clipboard images/files. Video references include six chronological frames (audio transcription remains explicitly unsupported).
- Demo: Instructions → edit → navigate away/back; ⌘, → global Instructions; ⌘N → attach a video/image → Add to Backlog. Project chat continues to propose, selectively queue, refine and resume tasks.
- Ten automated tests pass in approximately 42 seconds, including instruction changes on resumed project threads, New Task video ownership/frame delivery and the existing proposal/lifecycle flows.
- Visual/keyboard reinspection was blocked when Computer Use denied access to the separate preview app. Permission was requested; spoken VoiceOver and native capture confirmation also remain unverified. This is an implementation handoff, not a claim that every manual acceptance check has passed.

## Milestone 7 implementation handoff (2026-09-27)

- Settings: General/Hooks/Instructions, global agent/heavy-step limits, usage threshold, per-project editor/turn limits/plan approval/advanced controls, confirmed command editing, preview/check/recording settings and notification opt-in.
- Controls: default 15% account hold with Resume Anyway, Queue notices, bounded pause even with a slow configured CLI timeout, durable attention notifications, menu-bar Needs You/building/project-chat/usage controls, single-window reopening and active-agent quit confirmation. App observation continues when the main window is closed.
- Polish: persistent Merged board column, native Backlog multiselection with Move to Queue, sidebar shortcut and task Backlog/Cancel menu actions. Shared neutral native surfaces, accessibility names/tooltips and existing Reduce Motion/Transparency behavior are retained.
- Demo: ⌘, → change Agents at once → edit project settings or global Instructions. Open the menu-bar hammer to navigate an attention item or pause agents. Below the usage threshold, Queue cards wait; Resume Anyway permits dispatch. Backlog → Select Tasks → Command/Shift-click → Move to Queue.
- Ten process-boundary/state-machine tests pass in approximately 68 seconds (including the initial usage-read gate). Added coverage verifies legacy settings defaults, low-usage dispatch gating, failed-read hold retention, explicit override/recovery, stable attention identities and bounded pause with a fake app-server that ignores interrupts while the configured read timeout is 60 seconds.
- Manual acceptance is still pending: Computer Use denied access to the isolated preview app. Light/dark screenshots, native menu/Settings interaction, OS notification permission/delivery/deep-link, keyboard-only and spoken VoiceOver/Reduce Motion/Transparency checks have not been claimed to pass. A request to enable access remains pending. Milestone 5’s Bitbucket/stacking/watch/merge work is not included in this handoff.

## Conversation model selection brought forward (2026-09-27)

- Per-task and project-chat model/effort selectors are now v1. Project chat defaults to Astra High. Selections persist independently of lifecycle writes and apply to subsequent turns on the same thread, including after restart.
- Build and all ten tests pass in approximately 71 seconds. Extended existing process-boundary lifecycle/chat flows verify default Astra High, actual turn overrides, active-turn preservation, unsupported effort/model rejection, proof preservation and restart persistence. No new test suite or real inference calls were added.
- Installed Codex 0.151.0 currently does not advertise Astra, including hidden models. The default remains Astra High, with an explicit availability error; select an available model to chat on this installation. Native light/dark, keyboard-only and spoken VoiceOver acceptance remain pending because preview-app Computer Use access was previously denied.

## Delete active tasks (2026-09-27)

- Delete Task is available from the task toolbar, Task menu (⌘Delete), board/list/Needs You context menus and the project-chat task link. Confirm before stopping work and removing the local task and its worktree. Dependencies pause for review; branches and remote PRs remain.
- Eleven tests pass in about 74 seconds. The added process-boundary flow deletes a running fake-Codex task with dirty files, a live preview, task/chat attachments and a dependent task. It checks cleanup-hook failure/retry, process cleanup, navigation, durable record removal, branch/clone preservation, paused dependents and non-reuse of deleted task numbers.
- Manual confirmation-dialog, light/dark and VoiceOver interaction remain unverified; native UI automation access was previously denied.

Typing-bubble motion follow-up (2026-09-27): both chat transcripts retain the pending row’s identity when agent text arrives, animate its capsule into the message bubble, and expand new indicators smoothly. Existing history loads without replaying transitions; Reduce Motion skips geometry/scale animation. Build and eleven regression tests pass (~75 seconds). In-app motion, keyboard and spoken VoiceOver inspection remain pending; these are not established by the automated core suite.

## In PR chat feedback — 2026-09-27

Chat feedback on an open PR resumes the same task, worktree, branch and Codex thread through Building, with Needs Clarification for blocking questions. Existing pause, usage and concurrency limits apply. Prior proof is invalidated; after fresh review, Update Pull Request pushes the reviewed commit and refreshes the existing description without creating a second PR. Closed/merged PRs reject further feedback/publication; merge polling rechecks state before completing or cleaning up a task. This user-requested flow does not implement automatic CI/review watching, stacking repairs, Bitbucket or automatic merge.

Acceptance regression: publish, request changes while paused with an attachment, resume through clarification, produce a new commit and fresh proof, then update the same PR. Verify the bare remote branch receives the new commit, the PR is not duplicated, context/attachments survive and a closed or merged PR cannot be revised.

## UX review implementation — 2026-09-27

The owner approved the review in `docs/design/ux-review-2026-09-27.md`; checkpoint `18baa1e` preserves the application state and review before this implementation.

- Navigation leads the toolbar; editor/project actions and the details toggle are separate. Task pause and More sit beside its actual state. Model/effort stays at the composer. Instructions and project settings have explicit project-menu homes, with keyboard/menu alternatives retained.
- Conversations use content-sized Markdown bubbles, grouped timestamps, one remembered brief and details closed on first use. Questions, plan approval and Review remain reachable in the main surface. Both chats follow output only at the bottom, offer Latest when reading older messages, and preserve drafts across navigation. Project chat allows drafting during a response.
- The inspector shows recent task links, pinned compact Project information, disclosed worktree/history, readable changes and media before checks. Passed checks collapse; failure details stay visible and the publication action remains reachable.
- Board/list share useful notices and actions; redundant state/empty labels and Queue creation controls are removed. Drag previews preserve pickup geometry with a placeholder and restrained sibling motion. Search is scoped to task collections and remembers each context. Sidebar expansion and board/list/inspector/brief choices persist.
- New Task discloses optional controls. Project setup avoids a redundant repository check. Settings removes heavy-step and turn-budget controls while retaining meaningful project/security settings and diagnostics in human units. Background errors are scoped, dismissible and cleared by successful recovery. Automatic retries are quiet; three failed attempts or tool-free responses pause for review without imposing a lifetime turn ceiling.

Validation: the macOS app, core test bundle and optional UI-test target build successfully. All **13 process-boundary/state-machine tests pass in 86.4 seconds**, including existing task/PR/chat/attachment/deletion flows, navigation/search/draft/preferences persistence, quiet retries, exhausted recovery and resuming a task beyond the former turn ceiling. No real Codex/GitHub/Bitbucket requests were used by tests. The optional UI scenario was compiled, not run.

Actual SwiftUI chat/Markdown components were rendered offscreen in light/dark and at narrow widths; long paragraphs, lists and code wrap without clipping. Task-card light/dark renders verified narrow title and exception wrapping. The renderer cannot display all native button/drag layers and does not establish material or toolbar appearance. Native pointer dragging, typing/inspector transitions, focus and spoken VoiceOver still require manual verification. The earlier preview-app automation denial was respected; no live-desktop workaround or app restart was performed.

## Internal workload capacity follow-up — 2026-09-27

Verification and local previews now have separate capacity. Verification retains its internal default of two simultaneous jobs; at most two previews may be starting/running. Open previews cannot consume all verification slots and stall other tasks. Preview reuse, refusal of a third preview, 30-minute idle cleanup, Stop and quit cleanup remain. The fixed lifetime turn ceiling and heavy-step Settings control were already removed by the UX update; Agents at once remains the main scheduling control.

Validation: app/test build succeeds and all 13 tests pass in 90.6 seconds. Extended the existing preview flow to keep two HTTP previews serving while another fake-Codex task answers a question, commits and completes proof. It also retains third-preview refusal, unique ports, deduplication, startup failure/timeout, cancellation, deletion and quit cleanup coverage. Tests use process-boundary stubs and a local bare remote, with no real inference or hosted SCM mutations.

## Optional native subagents — 2026-09-27

Task agents and project chat now enable native Codex delegation automatically, with the parent responsible for the result and no additional settings. The optional details panel has a collapsed Subagents section showing names and status; selecting a child opens its available assignment and latest result. Records persist across app restarts. Children keep their own messages and usage, cannot invoke parent-owned Build Mate tools, and cannot finish the parent task. Review waits for active delegated work, including follow-ups that have been dispatched but have not yet started a turn.

Shutdown also reaps the direct CLI process after forced termination, fixing a race where a nonblocking exit check left a zombie process behind.

The process-boundary regression covers completed and active children, unrelated/missing-thread requests, stale root turns, duplicated activity, three premature review requests before one successful proof, result persistence, same-thread resumption, explicit child interruption and detached fake-command cleanup on Pause/shutdown. The existing project-chat flow verifies delegated results without unauthorized task creation. No real service calls enter the automated suite.

Offscreen light/dark renders verify the expanded list's narrow layout and the result sheet's header. Native scroll content is not fully represented by ImageRenderer; live sheet interaction, motion and spoken VoiceOver remain manual checks. The installed Codex 0.157.1 compatibility probe verified actual delegation and event routing; its native detached-command cleanup limitation is recorded in 08. The running user app is not restarted by this change.

Validation: the macOS app and test bundle build successfully; all **14 tests pass in 114.4 seconds**. The new regression exposed duplicate activity reactivation and an unreaped CLI process during shutdown; both are fixed and covered by the passing flow.


## Native Codex context and runtime defaults — 2026-09-27

Audited the installed CLI, native app-server schema and official documentation against Build Mate’s thread lifecycle. Task and project chats now retain successful input delivery per Codex thread, send only new messages/answers/attachments and changed guidance, and avoid full transcript/image replay. Resume excludes unused historical turn payloads and supplies current developer guidance. Project context carries a compact active-task index instead of every full brief. Existing threads bootstrap the delivery ledger once; unsuccessful sends remain pending.

Task defaults now use resolved Codex model/effort configuration, with explicit task/project selections taking precedence. Project chat retains Astra High. The picker displays the actual last-run defaults, or Codex default before resolution, instead of claiming the catalogue recommendation is active. Task replies stream, quiet shell commands retain their overall deadline without false silence stalls, and note-only loops cannot bypass no-progress protection. Proof commands are deduplicated, failed required checks defer captures, and failed-review responses include bounded redacted diagnostics. Native saved-image outputs reuse existing attachments/previews; native questions preserve secret/nonblocking semantics; unsupported permission/approval/elicitation requests decline explicitly without granting access.

Validation: app/test build succeeds; all **14 process-boundary/state-machine tests pass in 123.0 seconds**. Extended existing flows cover persisted input/attachment deduplication, changed guidance, failed delivery retry, steering, configured versus recommended defaults, streaming, quiet commands, note-only loops, native request responses, generated-image ownership/deduplication and proof efficiency. Tests use fake processes and local Git remotes, with no real inference or hosted SCM calls. The audit used read-only native metadata checks, not a quality/token/latency benchmark. Native UI interaction and Finder-launched desktop bridge parity remain unverified. The user’s running app was not restarted.

See [the runtime audit](../codex-runtime-audit.md) for measured metadata and intentional product differences; identical model/effort does not establish identical cost, speed or output quality.

## Workflow audit: correctness foundation — 2026-09-27

New work uses the freshly fetched host default branch and retains its base SHA. Proof and publication check requirement revisions. GitHub pushes the reviewed object, refreshes PR titles and descriptions, and repeated review cycles receive new attention identities. A process-boundary regression advances the bare remote beyond the user's local branch, verifies the new task includes it, rejects superseded requirements, and moves HEAD during publication to prove only the reviewed commit reaches the remote. App/test build and all 15 tests passed (126.8 s). Remaining audit implementation is tracked in `docs/workflow-delivery.md`; this does not claim the whole workflow is complete.

## Workflow audit follow-through (27 September 2026)

The current authorization extends delivery beyond the original milestone boundaries: state-aware intake, unpublished task split/combine with provenance, selective references, model recommendations, evidence inspection before human review, same-PR repairs, bounded CI reruns, GitHub-controlled merge, and fair scope-aware scheduling. Bitbucket authenticated integration remains deferred by explicit user choice. No remote daemon is added; monitoring runs while the Mac app is open.

Acceptance covers preserved source/dependency/model data during reshaping, stale-revision QA refusal, exact-commit publishing, feedback/reply recovery, inspected and bounded CI reruns, per-head merge approval, waiting-capacity release, and independent work continuing beside an overlapping scope. Test executables stub the process boundary; no test mutates real hosting services.


### Multi-repository project settings — 2026-09-28

- Native folder picker adds multiple Git repositories to one project; repository rows support unlinking without deleting files. Task and proposal views identify their repository when needed, and New Task requires an explicit target for multi-repository projects.
- Existing projects/tasks migrate without changing their target. Project chat inspects isolated read-only checkouts and coordinates separate tasks/PRs across repositories, including dependencies. Resumed conversations retain their native history and can use the updated task targeting through the compatibility tool path.
- Validation: build succeeded; all 21 process-boundary tests passed. The added flow covers migration, two-repository chat intake, dependencies, worktree isolation, PR targeting and safe unlinking. Native picker, repository selection and removal were exercised in an isolated app; settings were inspected in light and dark mode with accessibility labels exposed. No real Codex or hosting calls were made by tests; Bitbucket authenticated execution remains deferred.
