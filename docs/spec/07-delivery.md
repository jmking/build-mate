# 07 · Delivery

## Versions
| Version | Scope |
|---|---|
| **v1 — Mac** | Single app process; local Git projects plus projects on **GitHub and Bitbucket Cloud**; Codex app-server runner; built-in tracker; Needs You; project chat with proposals; Backlog; board (+ list view); New Task; task views for every state; clarification questions; plan/PR/merge approvals; proof of work (checks + recording); Run locally previews; Open in editor/Terminal/Finder; stacked PRs; PR watch mode; pause (task/project/all); project and global instructions; Settings (General, Hooks, Instructions); menu bar extra; notifications; usage meter and hold; light and dark mode. |
| **v1.1** | Ship as one PR (feature branch); `<n>.localhost` preview proxy; per-task model picker; list-view polish. |
| **v2 — Remote** | Settings › Remote, device pairing, private-network API, CloudKit push, iPhone Pro app, iPhone Duo layouts. |
| **v3** | Claude agent runner; Linear/Jira tracker adapters; Export to repository (`WORKFLOW.md`). |

## Milestones (v1)
Each milestone ends with a demo and its acceptance criteria passing.

1. **Spikes** (08): Codex app-server session lifecycle incl. `thread/resume`, `turn/steer`, `turn/interrupt`, tool mechanism; TWG CLI Bitbucket command mapping; recording approach.
2. **Core**: storage, data model, orchestrator loop, worktrees, hooks, Codex runner, retries, reconciliation, plus the e2e test harness (fake `codex`, `gh`, `twg` executables on `PATH` and a local bare git remote; see `AGENTS.md`).
3. **App shell**: window, sidebar, projects (Add Project), Needs You skeleton, task view transcript, board.
4. **Lifecycle**: questions, plan approval, proof runner, human review, previews, open-in-editor.
5. **PRs**: SCM providers (GitHub, Bitbucket), open PR, stacking, watch mode, merge rules.
6. **Project chat**: project agent, proposals, Backlog, New Task, instructions.
7. **Controls and polish**: pause, menu bar extra, notifications, usage meter, Settings, dark mode, accessibility, keyboard, empty and error states.

## Acceptance criteria (v1)
Test in light and dark mode; with VoiceOver; keyboard only; Reduce Transparency and Reduce Motion on.

**Projects and storage**
- Create New initialises a new or empty local folder on main, seeds an empty commit and adds it as a local project. Reject nonempty and nested-repository folders; no remote is created. Local tasks run in app storage and stop at Human review until publishing/local merge support is added.
- Adding a project from a local clone detects GitHub or Bitbucket Cloud, remote slug and default branch, and shows CLI sign-in status with a fix action.
- After a full task lifecycle, `git status` in the user's clone shows no new or modified files, and no files exist in the repo that Build Mate created.
- Removing a project deletes its data and worktrees and leaves the clone untouched.

**Project chat and backlog**
- Describing work produces a proposal card; **Add N to Backlog** creates tasks in Backlog with dependencies; **Add to queue** creates them in Queue.
- Typing "start the first two now, backlog the rest" results in exactly that, echoed as an event.
- Backlog tasks are never dispatched. Moving to Queue dispatches in rank order when a slot is free.
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

## Milestone 3 handoff (2026-09-26)

- **Demo:** launch → Add Project → Check Repository → Add Project → ⌘N → Add to Backlog → Move to Queue → ⌘4. The board reflects durable task state; a blocking question appears in Needs You and opens the persisted transcript. ⌘L toggles board/list, ⌘1–5 navigate, ⌘[/⌘] move through history, ⌥⌘I toggles the inspector, and ⌥⌘P pauses/resumes dispatch. Relaunch restores the selected task. Light/dark task and board layouts were inspected in the running app.
- Native shell implementation is delivered. Five automated tests pass (four process-boundary flows and the transition-rule unit test). Optional XCTest UI automation is compiled but blocked by the host's automation-mode initialization timeout; see 08. The follow-up acceptance pass checked keyboard flows and both system Reduce Motion/Transparency settings. Spoken VoiceOver verification remains blocked, so full accessibility acceptance is not claimed complete. See [acceptance record](10-milestone-3-acceptance.md).
- Scope still pending: review/playback/previews/editor actions (4), full SCM/PR controls (5), project chat/attachments/backlog ordering/instruction editing (6), usage/settings/menu bar/notifications/final accessibility polish (7). Board drag/drop is deferred with backlog ordering. No v2/v3 features were added.

- Follow-up demo: an unconfigured project can save to Backlog but cannot start; a configured fixture answers a question and restores its transcript after relaunch. The composer explicitly confirms whether a message was sent or saved without starting work.

## Task-specific proof follow-up (2026-09-26)

User-directed scope change ahead of the rest of milestone 4: remove the project-wide recording start gate. Automatic task proof selects evidence suited to the work, with user overrides. The app independently executes checks and validates required recordings before Human review. Playback, previews, editor actions and complete review controls still belong to milestone 4. The earlier unconfigured-project handoff describes the superseded behavior.

## New local projects follow-up (2026-09-26)

User-directed extension to project setup: Add Existing or Create New. A new project needs no hosting account and can run its first task in an isolated worktree. Multi-repository projects, remote creation/publishing and local merge are not included. The generic folder icon now also represents local projects.

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
