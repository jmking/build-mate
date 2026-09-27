# 04 · Mac UX

### Optional subagent activity (2026-09-27)

Task and project-chat details contain a collapsed Subagents section only after Codex delegates work. Keep it out of the toolbar and main transcript. The summary shows concise active/done counts, falling back to a total when stopped or failed children are present. Expanding reveals newest-first named rows with truthful status. A row opens a native read-only sheet with its assignment when available and latest completed result in Markdown. Long content scrolls, Done/Esc closes, buttons have tooltips and VoiceOver labels, and system colors support both appearances. No delegation toggle, child limit setting or separate Build Mate task is created.

Designs: `docs/design/png/{light,dark}/mac-*.png`, HTML references in `docs/design/html/`. The HTML draws each window at 1440×900 on a wallpaper so the glass materials show; the real app is a resizable window (minimum 900×620).

## 1. Information architecture
```
Main window
├─ Sidebar
│  ├─ Needs You (home, cross-project)                    ⌘1
│  ├─ Projects
│  │  └─ <project>  (GitHub or Bitbucket mark)
│  │     ├─ Chat                                          ⌘2
│  │     ├─ Tasks (board / list)                          ⌘3
│  │     │  └─ Task view (one per task, back/forward)
│  │     └─ Project menu → Instructions                   ⌘4
│  └─ Footer: agents busy · usage · Pause All · Settings
├─ Sheets: New Task, Add Project, Delete confirmations
Menu bar extra (popover)
Settings window: General · Hooks · Instructions (global) · Remote (v2)
```
⌘1–⌘4 act on the selected project. The last selected project and view are restored on launch; first launch opens Needs You (or Add Project if there are no projects).

## 2. Window anatomy (all main-window screens)
- **Sidebar** (232 pt, collapsible ⌃⌘S): system sidebar material (glass over the desktop), plain right border. Traffic lights at top-left; Hide Sidebar button at top-right of the sidebar.
  - **Needs You** row with a neutral count badge (total items waiting on the user).
  - **Projects** heading with **+** (Add Project). Each project row: disclosure chevron, neutral outline folder SF Symbol in the label colour, name, optional pause glyph (project paused), neutral badge = items needing the user in that project.
  - Expanded project children (indented): **Chat**, **Tasks** (badge = needs-you count). Expansion is remembered; on first use only the selected project opens. Instructions remains in the named Project menu and ⌘4.
  - Selection: neutral translucent fill, regular weight text, accent-tinted SF Symbols (HIG sidebar).
  - Footer: one compact activity row with **Pause All/Resume All** (⌥⌘P), then compact usage (see §13). Detailed account windows/reset times remain in the usage popover; holds and stale data are visible and announced by VoiceOver. Settings remains ⌘,.
- **Toolbar**: native unified toolbar with Back/Forward in leading navigation placement. Trailing groups contain contextual project/layout/creation actions, one icon-only editor action and a separated Details toggle using `info.circle`, visually distinct from the navigation sidebar toggle. Model/effort belongs beside the composer, task pause beside current task state, and Delete in the task More menu. Search appears only in Tasks and Needs You; each collection retains its own query. New Task appears once in Tasks, with ⌘N available throughout.
- **Content**: white (light) / window background (dark). Task views and the project chat let content scroll under the toolbar with a soft scroll-edge fade instead of a divider.
- **Inspector** (task views and chat, approximately 320–340 pt, toggle ⌥⌘I): slightly raised supporting panel, initially closed and thereafter remembered. Essential questions, plan approval and review availability remain in the main content. Pane widths adapt rather than shrinking text.

## 3. Needs You (home)
**Purpose:** decisions requiring the human across projects.
- Group project questions, task failures needing attention, questions to answer, plans to approve and changes to review.
- A row contains title, project and a short human-readable excerpt, opening its task/chat as one accessible native button. Normalize legacy JSON summaries; never show raw reports here.
- Automatic recovery is quiet. Only exhausted/paused failures notify the user. Exact diagnostic text is disclosed in context.
- Empty: “Nothing needs you.” A nonempty unmatched query shows “No matches” and Clear Search. Search includes project questions and names.
- No promotional slogan, task numbers, progress segments or redundant row actions.

## 4. Project chat — `mac-02-project-chat`
**Purpose:** talk to the project agent; turn intent into tasks.
- Toolbar: "Chat" + project name; **Open in <editor>** (opens the main checkout), Inspector toggle.
- Transcript: content-sized bubbles, readable maximum width, black/grey user and neutral agent surfaces, block Markdown for text/lists/code. Speaker identity is accessible without repeating visible author labels. Time separators appear after a meaningful gap; exact sender/time and copy actions are available from the message context menu and tooltip.
- Follow output only while the reader is near the bottom, including the first typing indicator, later typing indicators and growing streamed replies. Keep the bottom attached as their layout animates; programmatic scrolling must never disable following. Reading history or expanding a task brief preserves position; a Latest button appears for unseen messages or a newly started response. Initial history loads without replaying animation. Keep the typing indicator to message morph and Reduce Motion support.
- Composer: paperclip, screenshot, multiline message field and Send/Stop response, with a small model/effort picker beneath the input. Both chats use consistent spacing and alignment. Drafting remains possible during a response; project chat sends only when idle or answering a question. Preserve drafts when navigating.
- Every accepted/created task goes to Queue. Existing proposals retain their task selection and dependency behavior.
- Inspector: five most recent chat-created tasks, newest first, with View All Tasks opening the project’s task collection. Compact Project name/location is pinned at the bottom; branch, remote and full path are disclosed. No checkout implementation tutorial or duplicate Open Tasks button.
- Show the actual paused/usage/agent-wait reason only when relevant.

## 5. Task creation
Tasks are created manually from New Task or by the project agent and enter Queue directly. There is no separate draft-task state or view. Continue shaping ideas in project chat before accepting a proposal. Pause a task/project to hold queued work. Existing saved Backlog navigation restores to Tasks after upgrade.

## 6. Tasks board — `mac-04-board`
- Toolbar: “Tasks”; Project menu (Pause/Resume, Instructions and settings); List/Board control (⌘L); scoped Search; one New Task action (⌘N). Project controls are identical in board and list. A paused project exposes Resume directly.
- Columns: **Queue**, **Needs Clarification**, **Building**, **Awaiting human review**, **In PR**, **Merged**. Keep readable widths and visible horizontal scrolling. Header: icon, name and count. No extra Queue plus or repeated “No tasks” in empty columns; use one whole-board empty state.
- Queue contains tasks awaiting dispatch; dependencies, pause, usage holds and available slots govern when they start.
- Card (12 pt radius): optional attachment preview (image, or video with glass play button), title (3 lines max), attachment count, optional dependency title. Hide task numbers and the repeated column state/icon. Show only additional notices such as "Paused" or "Retry scheduled"; ordinary cards need no status row. Keep the task state in the card's VoiceOver label. Do not show segmented progress bars or the old Status checklist. Board and list have the same meaningful paused/dependency/usage/failure notices and task actions.
- Drag and drop reorders tasks within Queue; it does not change task state. Other state changes are agent-driven or use the task's explicit review actions.
- Context menu: Edit, Refine with Agent for Queue, ordering, Pause/Resume and Delete. Keep native menu-bar alternatives and no state changes on drag/drop.
- **List view** (not drawn): a table grouped by state, includes Merged and Canceled. Section headings use the same SF Symbol and icon colour as their board column, in a 16 pt icon slot with 6 pt spacing before the title. Keep the title in the native heading colour and hide the decorative symbol from VoiceOver. With no tasks, show “No work queued yet” and “Create a task or ask the project agent to create one.”

## 7. New Task sheet — `mac-05-new-task-sheet`
- Sheet attached to the main window (⌘N anywhere). Fields: project pull-down (neutral folder when an icon is shown), "What should be built" (multiline, initially focused), Attachments (picker, screenshot, drag-and-drop and paste). **Options** contains optional title, proof preference and plan-approval override.
- A nonblank brief is required. Save and open the task immediately with the user title or a locally shortened first line/sentence (at most 80 characters). Do not wait for Codex or scheduler work to dismiss the sheet. Refine an automatic title once in the background using an available economical model at its lowest supported reasoning effort; keep the local title if unavailable or unsuccessful. Manual titles/edits take precedence. Naming never starts a coding task or creates its worktree/session; Add to queue schedules coding independently. No model requests while typing.
- The task brief has a visible **Edit** action. **Task › Edit Task…** (⇧⌘E) and board/list context menus open the same native editor for title, brief and proof choice. Save Changes (Return) persists the draft; Cancel (Escape) discards it. Manual titles are never automatically replaced. Title-only changes preserve execution, proof, worktree branch and PR title.
- Editing the brief/proof before work starts preserves Queue and does not dispatch it. For started work, Save pauses and stops the worker, returns it to Queue for replanning, supersedes pending questions and old plan approvals, and invalidates previous proof. The user resumes explicitly; the same Codex thread and worktree continue with the updated brief. The editor explains this before saving. In PR, Merged and Canceled tasks allow title-only edits; the core rechecks state on Save.
- Footer: **Cancel** (esc) and **Add to queue** (primary, ↩). Show helper text only for a real blocker such as pause/usage hold; no title-generation or repeated queue tutorial.

## 8. Project instructions — `mac-06-project-instructions`
- Toolbar: "Instructions" + "Every agent in <project> follows these"; More (Export to repository… v3, Reveal data folder).
- Large text editor (markdown, 14 pt, 22 pt line height). Autosaves 1 s after typing stops; "Saved" appears in the caption.
- Caption: "Applies to the project chat and every task agent. Stored in Build Mate on this Mac, not in the repository; running agents pick up changes on their next turn."
- **Agents also follow**: `AGENTS.md` in the repository (line count, **Open**; row hidden if absent) and **Instructions for all projects** (Settings › Instructions, **Edit…**). Footnote: project instructions win on conflict.

## 9. Task view
- Native toolbar: leading Back/Forward, task title/project context, trailing icon-only editor and separated Details toggle. Editor menu retains installed app icons, Terminal, Finder and default editor selection.
- Compact content header: actual task state, task Pause/Resume, Review when ready, and More (Edit/Delete; suggested answers when applicable). State text uses primary foreground with a semantic glyph. Paused and genuine blockers are distinct conditions.
- One editable Brief disclosure, initially expanded for an unstarted task and otherwise remembered. No repeated inspector brief or lifecycle checklist.
- Conversation uses the same content-sized Markdown bubbles, timestamps, scroll-follow and composer as project chat. Unsent drafts survive task navigation. Routine state transitions remain under History.
- Pending questions and plans/Approve Plan are in the main conversation, reachable with the inspector closed. Do not render the same pending plan twice. Free-text answers use the composer; suggested answers require the existing review confirmation.
- The inspector leads with the change summary, recordings/screenshots and Changes. Failed checks are visible; passed checks and extended evidence/rationale collapse. Omit “Recording not required.” Keep preview setup in the preview-options menu.
- Worktree path/Terminal/Finder live under Task details, with labels/tooltips and unavailable-location errors. History is a disclosure. No unavailable worktree action opens a different folder.
- Review action opens details deliberately; the inspector never opens itself merely because work changed state. Its primary Open/Update Pull Request action remains pinned below scrolling evidence.
- Screenshot sheets retain Open in Preview (⌘O) and full screen (⌃⌘F). Full screen uses a dedicated native window, fits the image without cropping, and supports Escape/Close. Missing files show unavailable state.
- Human review and In PR chat accept feedback immediately, return to Building on the same thread/worktree/branch and preserve pause/usage limits. Blocking questions use Needs Clarification. Fresh proof is required before Update Pull Request. No routine explanatory branch/resumption paragraph in the composer.
- No manufactured Planning/Testing states. Lifecycle expansion requires genuine core transitions. Stacking/automatic PR watch remain the separate milestone-5 scope.

## 10. Menu bar extra — `mac-11-menu-bar-extra`
- `MenuBarExtra` with window style, 340 pt wide, glass.
- Header: "Build Mate", "N building", **Pause All**, **New Task**.
- **Needs you** list (dot, title, short status: "2 questions", "Input", "Approve plan", "Human review"), **Building** list (turn progress or "Paused"). Rows open the task in the main window.
- Footer: "3 in PR · 1 retrying", **Open Build Mate**.
- Menu bar icon: template image; shows a small dot when anything needs the user.

## 11. Settings — `mac-12-settings-general`, `mac-13-settings-remote`
Standard Settings window with toolbar tabs: **General**, **Hooks**, **Instructions**, **Remote** (v2). Settings apply immediately (no Save button).
- **General**: Agents at once, usage hold threshold, notification settings, per-project repository folders, default editor and plan approval. Repositories show name and abbreviated path, with a native multi-folder Add picker and per-row Remove. Only Git repositories are accepted; removing a link keeps files on disk and is blocked while unfinished tasks/worktrees use it. New Task shows a repository picker when the project has multiple links; task rows/details identify their repository. Project chat sees all linked repositories and assigns each proposed task to one repository. No Heavy steps or turn-budget control. Advanced retains branch prefix and network access; Diagnostics discloses durations in seconds/minutes. Both disclosures expand from the whole labeled row, support keyboard activation and VoiceOver expanded/collapsed state, and respect Reduce Motion. Contextual Project Settings selects the requested project even if the Settings window is already open. Notification status refreshes after returning from System Settings.
- **Hooks** (not drawn): per project: After create, Before run, After run, Before remove (multiline shell fields with timeouts), Preview command + port variable + ready path, Checks (list of name + command + required), Recording (command or agent-driven, required). Editing a hook requires confirmation ("Hooks run as you on this Mac").
- **Instructions**: global instructions editor (same component as project instructions).
- **Remote** (v2): Allow remote control, Keep this Mac awake while agents work, Paired devices (with Remove), Pair a Device… (QR sheet), privacy footnote.

## 12. Add Project (not drawn — design with the New Task sheet style)
Sheet with native **Add Existing / Create New** segmented choice. Add Existing: choose a local repository (including local-only repositories with an initial commit), detected host and remote (GitHub or Bitbucket Cloud with mark), default branch, CLI status ("gh signed in as …" / "Set up Bitbucket in TWG…" with a button that opens Terminal with `twg setup bitbucket`), optional quick setup (preview command, checks). Primary: **Add Project**, which inspects a typed path before adding. Choosing a folder already inspects it; do not require a second Check Repository step. Offer Check Again only when setup/authentication needs rechecking.

Create New: choose a new or empty folder, or type its full path (the parent must exist). The native folder panel permits creating a folder. **Create Project** runs `git init` on `main` and makes an empty initial commit so worktrees can branch immediately. Use the folder name as the project name. No starter files or remote are created. Reject nonempty folders and locations inside existing Git repositories before mutation. Failed creation preserves the folder; do not remove user files. The operation shows progress and prevents duplicate submission.

Local-only projects run tasks and collect proof without a hosting CLI. They stop at Human review with changes committed in the app-owned task worktree; publishing, local merge and PR actions are not implemented in this follow-up.

## 13. States not drawn (build to these rules)
- **Usage**: compact remaining amount in the sidebar; details/reset dates in the popover. Holds and stale data remain visible and accessible. Resume Anyway stays in the popover.
- **Paused banner**: when everything is paused, a glass banner under the toolbar in every window: "All agents paused" · **Resume All**.
- **Errors**: keep relevant to the affected task/project. Background diagnostics have a concise heading, Details disclosure and Dismiss. Clear recovered errors; dismissing an unchanged issue must not make it reappear every tick.
- **Loading**: skeleton rows in lists; never block the whole window.
- **First run**: welcome (what Build Mate does in three lines), sign in to Codex check, Add Project.

## 14. Menus and keyboard
| Command | Shortcut |
|---|---|
| New Task | ⌘N |
| New Project… | ⇧⌘N |
| Needs You / Chat / Tasks / Instructions | ⌘1 … ⌘4 |
| Toggle List/Board | ⌘L |
| Find | ⌘F |
| Back / Forward | ⌘[ / ⌘] |
| Open in default editor | ⌘O |
| Open in Terminal | ⌃⌘T |
| Show in Finder | ⌥⌘R |
| Pause/Resume task | ⌘. |
| Pause/Resume all | ⌥⌘P |
| Send message / primary action in sheets | ↩ (⇧↩ newline) |
| Approve (focused approval) | ⌘↩ |
| Toggle Sidebar / Inspector | ⌃⌘S / ⌥⌘I |
| Settings | ⌘, |

Menu bar menus: Build Mate, File (creation, editor/location), Edit, View (navigation/layout/panels), Project (chat, Instructions, settings, pause), Task (edit, order, review, preview, pause/delete), Window, Help. Global Pause All remains separately scoped. Every toolbar and context-menu action MUST be reachable from the menu bar.

## Milestone 3 implementation boundary

The initial milestone 3 shell delivered the sidebar, Add Project, Needs You summary, board/list, persisted transcript and inspector. The sections below record subsequent delivery and the current refinements; see 07 for validation status and 08 for setup assumptions. Native toolbar geometry and sidebar selection follow macOS controls.

Task proof: **Automatic** lets the agent choose checks and visual recording as appropriate to the task and brief. New Task also offers **Checks only** and **Checks + recording**; the inspector shows the choice, evidence rationale and whether recording was required. Missing recording configuration does not block Add to queue: evidence is proposed and checked before Human review. Bitbucket starts stay disabled until its provider is verified.

The send action’s tooltip/accessibility label distinguishes **Send answer**, **Send message** (an active Codex turn or review/PR feedback), and **Save message** (other states with no active turn). Saving persists the message for the next run and never starts or resumes a task. The transcript confirms submission without a routine sent/saved caption. Return submits; ⌘Return is also available. Unsent drafts survive navigation between tasks.

Retained retry diagnostics do not appear as a current Fix item while a recovered turn is running or waiting for a question/approval.

Queue ordering: picking up a Queue card/list row shows a raised native drag preview and fades its placeholder. As the pointer crosses another item's midpoint, surrounding items smoothly shift to preview the new order. Save priority only on a valid drop; Escape or dropping outside the group restores the original order. Reordering stays within a project and state; it never moves tasks into execution or interrupts an existing run. Top is highest priority. Context-menu Move Earlier/Later, accessibility actions, and Task menu ⌃⌘↑/↓ provide alternatives. Search preserves the full queue ordering. Reduce Motion disables the lift scaling and positional animations.

Usage UI: the compact sidebar shows remaining usage, holds and stale values. Its popover lists every reported bucket/window, progress bars, reset times, shared-account explanation, last refresh, errors and Refresh. Refresh on startup/every minute and consume live account notifications; an account-only app-server process creates no agent thread. Unknown windows/resets remain unavailable, never zero or invented. Failed refreshes retain clearly labelled last-known values. Automatic holds use the configured threshold (default 15%); Resume Anyway is available while held.

The composer omits routine delivery explanations. Actual blockers appear beside task status, with scoped pause/resume controls.

## Task identity in the interface (2026-09-26)

Use task titles, with project names where needed, to identify tasks. Hide internal task numbers from board cards, grouped lists, task-window subtitles, Needs You and their spoken accessibility labels; omit the former number column entirely. Dependency labels read “Waits on <task title>”. This supersedes numbered-task examples above. Keep task numbers internally for persistence, agent references, search compatibility and automation identifiers. Preserve real pull request numbers and original conversation text.


## Milestone 4 implemented lifecycle controls

- New Task includes **Plan approval** under Options: project default, ask before building, or build automatically. The override is stored atomically with task creation. A pending plan and Approve Plan appear in the main conversation even with details closed; Task › Approve Plan is also available.
- **Use Suggested Answers…** shows the agent's explicit suggestions for unresolved blocking questions in a confirmation sheet. Accepting records `agentDefault`; tasks remain paused if previously paused. The action is enabled only when every unresolved blocking question has a suggestion. Questions without suggestions require a normal answer.
- Human review shows the proof summary/rationale, check results with durations and clickable logs, an inline AVKit recording with native controls, Expand Recording in a separate window, and before/after screenshots that expand in a sheet. **Changes** shows per-file additions/deletions and Open File.
- **Chat review feedback** replaces Send Back. A message or attachment while awaiting human review or In PR automatically returns to Building, preserves the thread/branch/approved plan and invalidates proof. In PR feedback first verifies that the PR remains open. Paused task/project/global work stays paused; otherwise the scheduler resumes it when a slot is available. Task status reflects the transition. **Open Pull Request** and **Update Pull Request** recheck the reviewed commit and clean worktree; updates push the existing branch and refresh its PR description without creating a second PR. Local projects retain their committed worktree for editor/Terminal use. Full Bitbucket, stacking/watch/merge controls remain milestone 5.
- **Run locally** first offers project preview configuration if missing; saving never starts a process. Starting, ready, stopped and failed states expose Stop, redacted output and configuration. Ready opens the browser; later clicks reuse it. CLI/native projects can open their worktree in Terminal/editor instead.
- **Open in…** uses installed Cursor, VS Code and Xcode with their app icons; offers Terminal, installed iTerm/Ghostty, Finder, and per-project default editor. Task actions target its worktree; project actions target the clone. Missing/removed paths produce an actionable error. Shortcuts: ⌘O, ⌃⌘T, ⌥⌘R. Preview, changes, suggestions, plan approval, PR opening and recording expansion are also in the Task menu. All added buttons have help text.


Editor-icon refinement (2026-09-27): the Open in control shows only a centred 16 pt app icon and dropdown chevron; the editor name remains in its tooltip and accessibility label. Its dropdown uses the real installed app icons for editors, Terminal/iTerm/Ghostty and Finder. Retain the existing Default Editor submenu, with a checkmark on the selected editor; choosing it remains scoped to the current project. Use the native AppKit split button to explicitly preserve identifying menu images on macOS 27; macOS 26 uses its normal menu images. Tooltips and keyboard selection remain available.


## Project chat delivery brought forward (2026-09-27)

The Chat page now supports persistent text conversations, streamed agent bubbles, expandable inspection output, inline questions/answers, selectable proposals, Add N to Queue, and live task links in the From this chat inspector. Proposal dependencies are shown by task title. Unselected tasks are not created; dependencies of selected tasks must also be selected. Dismiss makes a proposal inactive. Every selected task is queued. Queued task row context menus and the Task menu expose Refine with Agent; scope changes to started work pause it for replanning. Project questions appear in Needs You and the Chat badge.

The glass composer uses the existing neutral bubble palette and system controls; ⌘Return/Return sends, Stop cancels, Retry continues an interrupted or failed conversation. Each project keeps its unsent draft while navigating and allows drafting during an active response. No additional messages are submitted during an active response except answers to its question. Project/global pause queues a message until resumed. The inspector lists the five most recent chat-created tasks with their live states. Task number breaks equal-time ties, newest first; priority and recent edits do not change this ordering. View All Tasks opens the project’s task collection. Project information stays pinned in a separate bottom section; branch, remote and full path are disclosed.

This pulls forward text project chat and task refinement, not all of milestone 6: image/video attachment entry and instruction editing remain separate remaining work. Proposal Ship as controls remain hidden until the related SCM capability exists. Spoken VoiceOver and reduced-transparency validation are not inferred from accessibility labels alone.


### Screenshot and file attachments (2026-09-27)

Both project and task composers offer a paperclip for the native multiple-file picker and a camera menu with **Capture Window…** and **Capture Area…**. Capture uses macOS's interactive selector: click a window or draw a rectangle; Escape cancels. The app temporarily hides during capture and returns with the image attached to the draft. macOS may request Screen Recording access. Capture never sends automatically.

Attachment controls are centered in 32-point square frames, matching the message field's minimum height. The composer keeps bottom alignment as multiline drafts grow, so the icons align with a single-line message without drifting to the middle of a longer draft.

Drop files or image data anywhere in the chat. Draft attachments show thumbnails/filenames, Preview and Remove actions. Files can be sent without message text (a question still needs a valid answer). Sent images appear in the conversation; clicking an attachment opens native Quick Look. Task brief attachments inherited from project chat are visible in task details. All controls have tooltips and accessibility names. Attachment bytes are cleaned up on merge as described in 02; removed files retain a filename placeholder.

This implements image/file attachments; video frame extraction and clipboard image paste remain separate from the delivered drag/drop, picker and screenshot entry points.

The ordinary project composer has no explanatory caption (user preference); retain the answer hint only while a clarification question is pending.

Both chat transcripts display a completed agent reply containing a single emoji as a small reaction badge overlapping the lower-right edge of the preceding user message, rather than a separate agent bubble. Keep the overlap shallow so the badge clears the message text, including short single-line replies; offset it down 24 pt and reserve the same space below the row. Emoji sequences such as skin tones and joined emoji count as one character. Activity/system events do not change the target; an intervening agent reply, question or proposal does. Replies containing prose, multiple emoji, unfinished streamed text or attachments remain messages. Preserve the original message in storage and agent context, apply the same presentation to saved history, and label the badge for VoiceOver as an agent reaction to the user's message. Respect Reduce Motion.

### Milestone 6 editor and attachment completion

Instructions are editable through Project › Instructions and Settings › Instructions, autosaved after one second and flushed on navigation. New Task includes the shared attachment controls and drop/paste support. Chat and New Task accept clipboard images/files with ⌘V. Videos show a thumbnail and supply six chronological frames to the agent; audio is not automatically transcribed.

### Milestone 7 controls

Settings (⌘,) has General, Hooks and Instructions tabs. Agents at once and usage threshold are editable; per-project settings cover editor and plan approval, with network/branch prefix under Advanced and timeouts under Diagnostics. Proof/preview capacity is internal and there is no lifetime turn limit. Hooks includes workspace hooks, local preview, checks and visual-proof commands, with an explicit command-editing confirmation. Incomplete checks stay drafts. PR creation remains explicit and automatic merging is unavailable pending milestone 5.

Menu-bar extra shows attention items, building tasks/project chats, paused state and account usage. Open and notification actions reuse the main window. Notifications are enabled from Settings and grouped by project; Open routes directly to the task or chat. Closing the window keeps the menu-bar app active. Quitting with active agents asks before stopping them.

Queue cards show “Waiting for usage” while held. The usage popover offers Resume Anyway. Merged is always a board column. Task menu includes Pause/Resume and Cancel Task, retaining history/worktrees. ⌃⌘S toggles the sidebar.


While an agent responds, project and task chats show a compact tailless three-dot bubble in the agent bubble colour. It expands smoothly on appearance and becomes the next agent text bubble in place, growing with streamed text. Waiting for input, queued and paused states retain explicit labels. The bubble is static with Reduce Motion enabled.

### Conversation model and effort (2026-09-27)

Task and project chat composers show the selected model and effort beneath the message field. The native popover provides model/effort pickers, supported choices from Codex, refresh, errors, tooltips and accessibility labels. Choices can be changed in any task state or during a response, persist across restart, and apply at the next turn without discarding history or interrupting work. A pending-change explanation appears when the current turn uses a different choice. Project chat defaults to Astra High; tasks inherit project/Codex defaults until changed. An unavailable configured model remains visible with guidance to choose another or update Codex; no silent fallback.

### Delete tasks (2026-09-27)

Every task state, including active work, has Delete Task in the visible task More menu, card/list context menu and Task menu (⌘Delete). A destructive confirmation names the task and explains removal of its conversation, attachments, proof and worktree, including uncommitted changes. Existing Git branches and hosted pull requests remain. Dependent tasks are paused for review. On success the open task returns to its project’s board, and navigation history drops the deleted task. Cancel closes the confirmation without modifying anything.

Task composer refinement (2026-09-27): omit the active-turn delivery caption and routine successful-send confirmation. The sent message in the transcript provides confirmation. Keep actionable questions, review availability and actual blockers visible in the main task surface.

### Readable task briefs (2026-09-27)

Render Markdown in the task brief, Brief inspector and proposed-task descriptions using Foundation’s Markdown parser with native SwiftUI block layout. Paragraphs have spacing; headings have hierarchy; bullet and numbered lists have hanging indents, including nested lists; inline emphasis/links and fenced code are retained. Use primary text for readable contrast. Editing continues to expose the original Markdown source. Existing plain-text descriptions are preserved, not automatically rewritten or sent to a model.

The project agent receives brief-formatting guidance on every turn, including resumed conversations: short goal paragraph, headings and bullets for substantial requirements, ordered lists for actual sequences, and blank lines between blocks. Keep simple tasks short and preserve scope/technical constraints when refining.

Credit-aware usage (28 September 2026): when usable Codex credits are reported, the compact footer shows their balance (up to two decimals), with included-usage windows still available in the popover. Missing balances show “Credits available”; unlimited credit access is labelled explicitly. VoiceOver includes the credit status. No new setting: the existing threshold applies only without usable credits.
