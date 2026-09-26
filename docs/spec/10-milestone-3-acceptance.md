# Milestone 3 acceptance — 2026-09-26

Status: implementation and process-boundary tests delivered; spoken VoiceOver acceptance remains outstanding. No milestone 4 implementation was started in this follow-up.

## Automated evidence

- `BuildMate`: build-for-testing succeeds; five tests pass through direct `xctest` (about 11 seconds). Four process-boundary flows plus the state-machine transition test.
- Extended the existing shell flow: missing/signed-out gh, duplicate clone, task creation, absent recording command blocks both start paths, pre-existing Todo cannot launch Codex, saved message persists without dispatch, restoration, disabled Bitbucket, untouched clone.
- Existing lifecycle flow verifies live `turn/steer` returns sent and still reaches merged/Done. All external integrations use fake executables; git uses a local bare remote.
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
