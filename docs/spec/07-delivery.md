# 07 · Delivery

## Versions
| Version | Scope |
|---|---|
| **v1 — Mac** | Single app process; projects on **GitHub and Bitbucket Cloud**; Codex app-server runner; built-in tracker; Needs You; project chat with proposals; Backlog; board (+ list view); New Task; task views for every state; clarification questions; plan/PR/merge approvals; proof of work (checks + recording); Run locally previews; Open in editor/Terminal/Finder; stacked PRs; PR watch mode; pause (task/project/all); project and global instructions; Settings (General, Hooks, Instructions); menu bar extra; notifications; usage meter and hold; light and dark mode. |
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
- Adding a project from a local clone detects GitHub or Bitbucket Cloud, remote slug and default branch, and shows CLI sign-in status with a fix action.
- After a full task lifecycle, `git status` in the user's clone shows no new or modified files, and no files exist in the repo that Build Mate created.
- Removing a project deletes its data and worktrees and leaves the clone untouched.

**Project chat and backlog**
- Describing work produces a proposal card; **Add N to Backlog** creates tasks in Backlog with dependencies; **Start Now** creates them in Todo.
- Typing "start the first two now, backlog the rest" results in exactly that, echoed as an event.
- Backlog tasks are never dispatched. Moving to Todo dispatches in rank order when a slot is free.
- Refine with Agent updates the description and any questions appear in the chat.

**Lifecycle**
- A task whose agent asks a blocking question moves to Needs Clarification, appears in Needs You, and resumes within 5 s of the last answer, with the same Codex thread (context retained).
- With "Ask me before starting to build" on (project or task), the task waits in Todo with an Approval in Needs You; Approve Plan starts building.
- A task cannot enter Human review until required checks pass and the recording exists; failed proof returns to the agent with the failure.
- Run locally starts the preview on a unique port and opens the browser within 90 s, for two tasks at once without port clashes.
- Open Pull Request creates the PR on the right host; dependent tasks create stacked PRs targeting the base task's branch; after the base merges, the dependent PR is rebased and retargeted to the default branch automatically.
- In PR, a failing required check triggers the agent to fix and push without user action; a decision question appears under Decisions in PR.
- With "Ask me before merging" off, the agent merges (squash, delete branch) only when required checks and approvals pass; it never uses admin bypass.

**Control**
- Pause task stops the session after the current step within 30 s, keeps the worktree, and Resume continues the same thread.
- Pause Project and Pause All stop dispatch and pause running tasks; the sidebar and menu bar show paused state; Needs You still updates.
- Usage below the hold threshold stops new dispatch and shows "Waiting for usage" on Todo cards.

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

- **Demo:** launch → Add Project → Check Repository → Add Project → ⌘N → Add to Backlog → Move to Todo → ⌘4. The board reflects durable task state; a blocking question appears in Needs You and opens the persisted transcript. ⌘L toggles board/list, ⌘1–5 navigate, ⌘[/⌘] move through history, ⌥⌘I toggles the inspector, and ⌥⌘P pauses/resumes dispatch. Relaunch restores the selected task. Light/dark task and board layouts were inspected in the running app.
- Native shell implementation is delivered. Five automated tests pass (four process-boundary flows and the transition-rule unit test). Optional XCTest UI automation is compiled but blocked by the host's automation-mode initialization timeout; see 08. The follow-up acceptance pass checked keyboard flows and both system Reduce Motion/Transparency settings. Spoken VoiceOver verification remains blocked, so full accessibility acceptance is not claimed complete. See [acceptance record](10-milestone-3-acceptance.md).
- Scope still pending: review/playback/previews/editor actions (4), full SCM/PR controls (5), project chat/attachments/backlog ordering/instruction editing (6), usage/settings/menu bar/notifications/final accessibility polish (7). Board drag/drop is deferred with backlog ordering. No v2/v3 features were added.

- Follow-up demo: an unconfigured project can save to Backlog but cannot start; a configured fixture answers a question and restores its transcript after relaunch. The composer explicitly confirms whether a message was sent or saved without starting work.
