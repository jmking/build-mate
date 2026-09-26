# Milestone 3 acceptance — 2026-09-26

Status: implementation and process-boundary tests delivered; spoken VoiceOver acceptance remains outstanding. Historical checks below predate the user-directed task-specific proof follow-up in 07/08, which supersedes the recording setup/start gate.

## Automated evidence

- `BuildMate`: build-for-testing succeeds; five tests pass through direct `xctest` (about 11 seconds). Four process-boundary flows plus the state-machine transition test.
- Extended the existing shell flow: missing/signed-out gh, duplicate clone, task creation, absent recording command blocks both start paths, pre-existing Todo cannot launch Codex, saved message persists without dispatch, restoration, disabled Bitbucket, untouched clone.
- Existing lifecycle flow verifies live `turn/steer` returns sent and still reaches Merged. All external integrations use fake executables; git uses a local bare remote.
- `BuildMateUI` build-for-testing succeeds. Execution is not claimed: Xcode's UI automation-mode initialization timed out on this host. The scenario covers light/dark setup, board, transcript, readiness gates, composer confirmation and relaunch.

## Interactive evidence

Used an isolated data directory and copied fake executables on PATH. No real Codex or hosting service was used.

| Check | Result |
|---|---|
| Setup errors | Missing folder reports an actionable error. Missing gh offers install/sign-in command; signed-out gh offers sign-in; authenticated fixture shows host, slug and main branch. |
| Keyboard setup | Return checks repository; Tab/Space adds project; ⌘N opens New Task. Native multiline description uses Control-Tab to leave the editor. |
| Start readiness | Start Now and Move to Todo disabled with explanation before recording configuration; Add to Backlog works. Configuring the isolated fixture enables Move to Todo. |
| Question | ⌘1 opens Needs You; Tab/Space opens task and selects an answer; text answer submits with ⌘Return. Plan appears afterwards; approving it completes the fake build/proof and reaches Human review. |
| Navigation | ⌘4 opens Tasks; ⌘L toggles list/board; history returns to task. Existing shell run checked inspector and search shortcuts. |
| Message delivery | Active turn shows Send message; after restart with no turn, Save message confirms no start/resume and appends the note to the transcript. |
| Relaunch | Needs You selection, questions, answers, plan and transcript persist when relaunching the fixture in dark mode. |
| Appearance/reduced effects | Inspected light and dark shell/transcript and dark list with Reduce Motion and Reduce Transparency enabled. Text and controls remain legible; native material surfaces adapt. Restored both settings, keyboard navigation and VoiceOver to original off values. |
| VoiceOver | Labels and accessible controls inspected. Reader inspection timed out and speech/focus traversal could not be verified reliably. This is still an acceptance blocker. |

The fake agent deliberately asserts the exact answer `Plain`. A manual free-text answer `Plain output, please.` crashed that fixture; retry surfaced in Needs You and the exact answer continued to plan approval. This is not evidence of a real Codex failure. It also exposed a stale “Retry scheduled” label during recovered work. The shell now hides retained retry diagnostics while a turn is active or a question/approval is pending; the core retains its retry counter.

## Design comparison and boundaries

Compared against the light/dark Mac references, especially mac-01, 03, 04, 05, 07 and 08. Sidebar hierarchy, sectioned Needs You, five board columns, task brief/transcript/composer, inspector and state colours are implemented with native controls. Added sidebar counts. Native toolbar geometry, focus rings and sheet layout take precedence over custom HTML chrome. Reduced effects use system behavior.

This is shell acceptance, not complete v1 visual parity: rich proof/review/preview/editor actions are milestone 4; PR controls are 5; attachments, project chat, backlog ordering/drag-and-drop and editable instructions are 6; settings, usage, notifications and menu bar extra are 7. Later actions are omitted or explicitly marked unavailable. Fresh projects cannot run until proof configuration is available; the demo configuration was applied only to the disposable fixture.

## Remaining sign-off

Run a human VoiceOver pass in both appearances: add a project, create a Backlog task, traverse board/list and transcript, answer a question and inspect the delivery confirmation. Verify spoken labels, order and focus after sheets close. Do not mark full milestone accessibility acceptance passed until this is observed.

## Design follow-up

Compared the implemented Mac surfaces with the light/dark references and Apple's current material/motion guidance. Refined the floating composer, native inspector, event/message hierarchy, progress checklist, board surfaces and description editor. Added scoped native animations for navigation, panels, project disclosure and board updates; do not animate every database refresh or streaming character.

Interactive checks used populated paused fixture data: light/dark board and transcript, native inspector keyboard close/open, board/list navigation, New Task sheet presentation/dismissal, and the solid composer fallback with Reduce Transparency. Reduce Motion and Reduce Transparency were temporarily enabled and restored to their original off values. This verifies layout and interaction states, not a frame-time/performance benchmark. Spoken VoiceOver sign-off remains as recorded above.

## Automatic title follow-up — 2026-09-26

New Task now focuses the brief and hides manual naming behind “Set a title yourself”. Verified description-only creation in light and dark mode, generated title in the task/window, manual override, rename persistence across relaunch, and Return to save the rename. The native accessibility tree exposes the description, optional title, rename control and rename text field by name. Visual verification caught and fixed a sheet-dismissal cancellation of the successful save's final refresh.

The existing process-boundary shell flow now covers generated naming without a worktree/session, preserving the brief, manual rename, malformed-response fallback and cancellation during a stalled title turn (no saved task, scratch directory removed). All five tests pass in approximately 14 seconds. The native UI scenario was extended and compiled; the previously documented XCTest automation-host and spoken VoiceOver limitations remain. A separate manual real-Codex probe verified ephemeral read-only structured output in 3.69 seconds; automated tests still use fake CLIs only.

## Whole-card navigation follow-up — 2026-09-26

All Needs You sections now use the complete card as a native button, with a rectangular hit area covering the padding and spacer. Removed the separate Open/Review button; a trailing chevron indicates navigation. The accessible button label includes task, project, number and reason, with an “Opens the task” hint. Verified light/dark rendering, card activation and a pointer click in the blank middle of the card opening the correct task. Existing five-test suite passed in 13.175 seconds; no extra tests for this small presentation change.

## Project folder icon follow-up — 2026-09-26

Replaced the hosting-service logo with the neutral outline folder SF Symbol. Verified light/dark rendering and the project name/pause accessibility label without redundant hosting text. Build passed. The first regression run hit SQLite error 5 (`BEGIN IMMEDIATE TRANSACTION`) in the unchanged scheduler/restart test; an unchanged rerun passed all five tests in 12.937 seconds. This records an intermittent test failure, not a SQLite fix. No additional tests for the decorative icon change.


## Text alignment pass — 2026-09-26

Corrected the composer’s short-field/tall-button bottom alignment with optical text insets and matched native control sizing. Applied first-baseline alignment to form rows and footers, setup grid cells, transcript metadata, Needs You cards and task lists. Task lists reserve consistent number space and keep multiline titles leading aligned. The visual pass also found native list separators starting underneath the trailing status label; explicitly aligned them to the row leading edge.

Manually inspected the composer empty and with multiline text, task brief/inspector, long wrapped card/list titles, board, New Task and Add Project (including discovered repository metadata). Checked light and dark appearance in isolated fixtures; the original fixture title was restored afterward. Native controls and accessibility identifiers remain intact. Build and the existing five-test suite pass; no new tests for these layout-only changes. Spoken VoiceOver and the previously documented XCTest UI-host limitation remain unverified.

## Icon and spacing pass — 2026-09-26

Replaced the manually sized project HStack with a native sidebar Label, giving the project folder and Needs You the same icon/title columns and keeping child pages consistently indented. The folder stays in neutral label colour. Normalised small add-control frames, Needs You status/chevron slots, board header glyph widths and header heights, and card metadata baselines. Reviewed the remaining form, transcript, composer and progress rows against the preceding alignment pass; retained their native labels and existing aligned layouts.

Verified the sidebar, board and Needs You in light and dark fixtures, project collapse/expand, navigation shortcuts and exposed accessibility labels. No new layout tests; spoken VoiceOver and XCTest UI-host limitations remain as documented.

Build passed. The restart test reproduced the earlier SQLite lock twice: its thread-ID assertion used `session(for:)`, which opens a get-or-create write transaction through the old Store while the reopened Store is active. Changed that assertion to read existing sessions without a competing write; production storage behavior is unchanged. All five tests then passed twice, in 13.161 and 13.169 seconds.

## Task-specific proof and new local projects — 2026-09-26

User-directed follow-up beyond the original shell boundary. New Task exposes Automatic, Checks only and Checks + recording. Automatic uses the agent's task assessment and brief instructions; explicit choices are enforced by the runner. Proof has a rationale, independently executed checks and a recording only when needed. Functional tasks no longer need recording setup before starting. The native app migrated the older fixture database successfully.

New project setup offers Add Existing and Create New. Manual light-mode demo: choose Create New, type a scratch path, press Return, and see the new project's board. Verified its empty initial commit and clean working copy. In dark mode, trying that occupied folder again produced the intended error without changing it. Inspected proof selection in both appearances, including choosing Checks only and enabled Start Now for a local project. Accessibility trees expose the segmented choices, folder field, proof picker and action buttons; spoken VoiceOver remains outstanding.

Build and seven tests pass (18.376 seconds): the new proof flow covers functional evidence, visual evidence, both user overrides, missing/invalid recordings, missing checks, legacy summary-only tool compatibility and denial of proof writes outside allowed folders. The new local-project flow covers new/empty folders, duplicate/nonempty/nested rejection, no remote, pause/resume, first-task execution and proof in an app-owned worktree, a clean source repository, and rejecting PR publication. Tests still use fake Codex/hosting processes and real local Git. Full review playback, previews, editor controls, publishing and local merge remain later work.

## Edit existing tasks — 2026-09-26

Replaced the title-only pencil with a visible Edit action, Task menu shortcut ⇧⌘E and board/list context actions. The native sheet edits title, brief and proof choice with explicit Save Changes and Cancel. Started work pauses on scope changes; old proof, plan approvals and unanswered questions are superseded, and Resume replans in the same thread/worktree. Published and terminal tasks permit title changes only.

Manually verified light/dark sheet layout, populated fields, saving all three values, immediate detail/inspector updates, persistence after relaunch, Escape cancelling a draft, Return saving and the menu shortcut. Checks used isolated paused fixtures; restored the fixture content afterward. Accessibility labels are exposed for every field and action; spoken VoiceOver remains outstanding.

Build and the existing seven tests pass in 19.690 seconds. Extended existing flows cover Backlog editing without dispatch/session creation, empty-title rejection, editing while waiting for an answer, invalidating reviewed proof, resuming with a fresh plan and updated prompt on the same thread, rejection of premature PR publication, and title-only editing after publication. The optional native UI test target compiles; the previously recorded UI automation-host limitation remains.

## Merged workspaces, queue ordering and usage — 2026-09-26

Merged tasks now release clean worktrees after the removal hook, retaining their task history, proof and local branch. Untracked/modified files prevent deletion; reconciliation retries later and clears its cleanup error after success. The existing lifecycle flow covers both refusal and successful retry after restart.

Backlog and Todo priorities are persisted transactionally without changing task state. Existing process-boundary flows verify ordering in both directions, cross-state rejection and dispatching the newly highest-priority Todo first. Move Earlier/Later actions and Control-Command-Up/Down provide alternatives to dragging. Automated pointer input initiated a drag but failed to deliver a drop; the owner confirmed physical Todo dragging works. The first native Backlog list implementation did not move rows, so it was replaced with the same item-provider/drop-delegate handling used by cards. After relaunch, the fixture Backlog order changed from #7/#8/#10 to #8/#7/#10 and persisted in SQLite during the owner’s manual check; final interaction feedback was still pending when recorded.

The sidebar usage button opens account-wide windows, percentages remaining, reset times and Refresh. Inspected the footer and popover in light/dark appearances and their accessibility labels; manual Refresh updates the timestamp. The process-boundary usage flow covers multi-bucket preference, most constrained Codex window, legacy responses, unknown values, failure with retained last-known data, and no thread/turn creation. Automatic usage holds and the menu bar extra remain later work. Native material tint is unchanged following the owner's observation that Apple apps have the same appearance.

Build and all eight tests pass in 24.075 seconds. The optional native UI target compiled earlier in this pass; it was not run because of the previously recorded automation-host limitation. Spoken VoiceOver sign-off remains outstanding. All interactive checks used a paused isolated fixture; the owner's active app/task was left running.

## Neutral surface palette — 2026-09-26

Owner-directed reversal of the earlier native-tint decision. Matched the reference charcoal window, darker board columns and elevated card colours, with corresponding white/cool-grey light surfaces. Applied a shared adaptive SwiftUI surface palette to window content, sidebar, sheets, inspector, list, cards and usage popover. Toolbar controls and composer retain native Liquid Glass, system labels/accents and existing motion. No global desktop or accessibility preferences changed.

Compared the reference Mac board and New Task images in both appearances. Visually checked the rebuilt dark board, Add Project, New Task, transcript/inspector/composer, plus the light board, Edit Task, Backlog and usage popover in the isolated paused fixture. Native sheet dismissal and keyboard navigation still work. Build and all eight existing tests pass in 24.428 seconds; no new tests for this colour-only change. Existing spoken VoiceOver sign-off remains outstanding.


## Immediate creation with economical title refinement — 2026-09-26

Creation now saves a local brief-derived title and opens the task before network naming or scheduler work. A single ephemeral Luna/mini naming turn refines it in the background, using the lowest advertised supported effort. Manual override skips naming; subsequent edits cancel it. No qualifying economical model means retaining the local title, never silently choosing the project/default coding model. Shutdown retains the task and cleans up naming processes/directories.

Extended the existing shell process-boundary flow instead of adding another test. It covers immediate provisional title/display, eventual generated title, malformed output, no economical model/no thread creation, a stalled model with creation under one second, manual rename winning over pending generation, and saved-task/scratch cleanup on shutdown. Measured creation at 0.001285 seconds with naming deliberately stalled. Build and all eight tests pass in 26.070 seconds.

Manual UI demo in the isolated dark fixture: entered a brief without a title, clicked Add to Backlog, and immediately reached the persisted task detail while the fake model remained stalled. Existing native sheet, labels and keyboard behavior are preserved; this change introduces no layout or colour changes. Separately verified the real installed GPT-5.6 Luna at low effort: valid structured title in 4.388 seconds, entirely off the creation path. No claim that network refinement itself is instantaneous.

## Conversation bubbles and clearer composer hint — 2026-09-26

Agent messages now share the human message bubble fill, padding, maximum width and corner radius. Agent bubbles align left and human bubbles right, with speaker/time inside; events and interactive questions keep their existing presentation. Replaced the inactive composer hint with the owner-approved “Messages are saved for when work resumes.” Delivery behavior is unchanged.

Verified a populated agent–human–agent exchange and the new hint in both light and dark isolated fixtures; text remains selectable and the accessibility tree preserves message content, speaker/time and composer labels. Bubble regression build and all eight existing tests passed in 25.105 seconds; the final text-only follow-up build also passed. No additional tests for these presentation-only changes.
