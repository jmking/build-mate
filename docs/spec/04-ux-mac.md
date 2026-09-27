# 04 · Mac UX

Designs: `docs/design/png/{light,dark}/mac-*.png`, HTML references in `docs/design/html/`. The HTML draws each window at 1440×900 on a wallpaper so the glass materials show; the real app is a resizable window (minimum 1100×700).

## 1. Information architecture
```
Main window
├─ Sidebar
│  ├─ Needs You (home, cross-project)                    ⌘1
│  ├─ Projects
│  │  └─ <project>  (GitHub or Bitbucket mark)
│  │     ├─ Chat                                          ⌘2
│  │     ├─ Backlog                                       ⌘3
│  │     ├─ Tasks (board / list)                          ⌘4
│  │     │  └─ Task view (one per task, back/forward)
│  │     └─ Instructions                                  ⌘5
│  └─ Footer: agents busy · usage · Pause All · Settings
├─ Sheets: New Task, Add Project, Delete confirmations
Menu bar extra (popover)
Settings window: General · Hooks · Instructions (global) · Remote (v2)
```
⌘1–⌘5 act on the selected project. The last selected project and view are restored on launch; first launch opens Needs You (or Add Project if there are no projects).

## 2. Window anatomy (all main-window screens)
- **Sidebar** (232 pt, collapsible ⌃⌘S): system sidebar material (glass over the desktop), plain right border. Traffic lights at top-left; Hide Sidebar button at top-right of the sidebar.
  - **Needs You** row with a neutral count badge (total items waiting on the user).
  - **Projects** heading with **+** (Add Project). Each project row: disclosure chevron, neutral outline folder SF Symbol in the label colour, name, optional pause glyph (project paused), neutral badge = items needing the user in that project.
  - Expanded project children (indented): **Chat**, **Backlog** (plain count), **Tasks** (badge = needs-you count), **Instructions**.
  - Selection: neutral translucent fill, regular weight text, accent-tinted SF Symbols (HIG sidebar).
  - Footer: "N of M agents busy" (tabular numerals), usage meter (see §13), **Pause All** (⌥⌘P), **Settings** (⌘,).
- **Toolbar** (unified, 52–56 pt): title (15 pt semibold) and optional subtitle on the left; grouped Liquid Glass controls on the right. Related controls share one capsule (for example Search + New Task; Back + Forward; Inspector + More).
- **Content**: white (light) / window background (dark). Task views and the project chat let content scroll under the toolbar with a soft scroll-edge fade instead of a divider.
- **Inspector** (task views and chat, 340 pt, toggle ⌥⌘I): slightly raised background, content starts below the toolbar.

## 3. Needs You (home) — `mac-01-needs-you`
**Purpose:** everything waiting on the user across all projects, answerable in place.
- Toolbar: "Needs You" + "7 across 2 projects"; Search, New Task.
- Every Needs You card opens its task when clicked anywhere, including its whitespace. Use one native button with a subtle trailing chevron, keyboard activation and an accessible task/reason label; no separate Open/Review button. Future inline answer/approval controls retain their own actions.
- Sections, in this order, only when non-empty:
  1. **Questions**: row = status dot (needs-you purple), task title, project · #number, the question text, answer chips. Clicking a chip answers immediately (optimistic, undo toast for 5 s). If the question allows free text, opening the card focuses the task composer.
  2. **Approvals**: plan approvals and merge approvals. Row = title, project · #number · reason ("you asked to approve the plan"), plan summary, **View Plan** (opens the task scrolled to the plan) and **Approve Plan** (or **Merge**).
  3. **Decisions in PR**: blocking questions raised while a task is In PR (same row as Questions).
  4. **Ready for human review**: recording thumbnail (glass play button), title, project · #number · recording length · checks, Road-to-merge bar, **Open Preview**, clickable card (opens the task view).
- Empty state: large SF Symbol `checkmark.circle`, "Nothing needs you", secondary line "Agents are working on N tasks." with a link to the busiest project.
- Updates live; newly arrived items highlight briefly (respect Reduce Motion).

## 4. Project chat — `mac-02-project-chat`
**Purpose:** talk to the project agent; turn intent into tasks.
- Toolbar: "Chat" + project name; **Open in <editor>** (opens the main checkout), Inspector toggle.
- Transcript (max width 720, centered):
  - User messages: right-aligned grey bubbles with attachments (images/video thumbnails, 220×140).
  - Agent messages: left-aligned grey bubbles, matching the user bubble padding and radius, with speaker and time inside.
  - Activity rows: collapsed pill "Read 22 files in reports/ and exports/ · 2 min" with chevron; expands to the raw tool list.
  - Events: centered small grey line with hairlines ("#427 and #428 in Queue · #429 in Backlog").
  - **Proposal card** (from `propose_tasks`): header "3 tasks for acme/web · each gets its own agent and worktree"; one row per task with a checkbox (checked by default), number, title, "after N" dependency chip, one-line plan; footer: **Ship as** pull-down ("3 PRs, #2 stacked on #1" / "One PR (v1.1)"), **Add to queue** (secondary), **Add N to Backlog** (primary, default). Unchecking a task excludes it. After creation the card collapses to a summary with links to the tasks.
  - Task chips after creation: glass capsules "● #427 Building" that open the task.
- Composer (floating glass, bottom): attach (paperclip; also drag-and-drop and paste images/video), text field "Describe what you want built…", send (accent circle, ⌘↩ or ↩).
- Natural-language routing: "start now", "go straight to Queue" → Add to queue; "backlog the rest" etc. The agent echoes the outcome as an event.
- Inspector: **From this chat** (only the most recently created chat task, live state, "Backlog · waiting for you to refine", "then waits on #427") and a fixed bottom **Project** section (checkout path, branch, agent, host mark + remote slug, **Open Tasks**). Project information stays outside the task scroll area and remains visible.

## 5. Backlog — `mac-03-backlog`
**Purpose:** refine tasks before any agent starts them.
- Omit the trailing state icon/label on Backlog rows: the page already identifies their state. The grouped Tasks list also omits these repeated labels because its section headings identify each state.
- Toolbar: "Backlog" + "4 tasks · agents won't start these until you move them to Queue"; Search, New Task.
- Left list (420 pt): drag handle, title, one-line description, meta ("From chat · today", "2 attachments", "Waits on #412"), number. Drag to reorder (sets start order). Multi-select with ⇧/⌘; **Move to Queue** acts on the selection (⌘↩).
- Right editor: "#429 · Backlog · created from Chat at 09:11"; title (large inline field); Description (text editor, markdown); Attachments (tiles + add); settings list: **Depends on** (pull-down, multiple), **Ship as** (Its own PR / stacked / one PR v1.1), **Ask me before building** (Use project setting / On / Off). Footer: **Delete…** (destructive, confirm), **Refine with Agent** (sparkles; the project agent rewrites the description and asks questions in the chat), **Move to Queue** (primary).
- Empty state: "Backlog is empty" + "Tasks you add from the chat land here."

## 6. Tasks board — `mac-04-board`
- Toolbar: "Tasks"; **Pause Project**; List/Board segmented control (⌘L toggles); Search; New Task (⌘N).
- Columns (left to right): **Queue**, **Needs Clarification**, **Building**, **Awaiting human review**, **In PR**. Merged is reachable from the list view filter and search (not a column). Column: 20 pt radius, 8 pt padding, header icon + name + count; Queue header has **+**.
- Queue contains only queued tasks. Backlog is accessed from the project sidebar; do not repeat its link or count inside Queue.
- Card (12 pt radius): optional attachment preview (image, or video with glass play button), title (3 lines max), attachment count, optional dependency title. Hide task numbers and the repeated column state/icon. Show only additional notices such as "Paused" or "Retry scheduled"; ordinary cards need no status row. Keep the task state in the card's VoiceOver label. Do not show segmented progress bars on board or Needs You cards; the Status checklist lives in task details.
- Drag and drop reorders tasks within Backlog or Queue; it does not change task state. Use explicit actions to move tasks between Backlog and Queue. Other state changes are agent-driven or use the task's explicit review actions.
- Context menu: Open, Open in <editor>, Pause/Resume, Move to Backlog, Cancel Task…, Copy Link.
- **List view** (not drawn): a table grouped by state, excluding Backlog tasks because they have their own view; includes Merged and Canceled. Section headings use the same SF Symbol and icon colour as their board column, in a 16 pt icon slot with 6 pt spacing before the title. Keep the title in the native heading colour and hide the decorative symbol from VoiceOver. With no tasks outside Backlog, show “No work queued yet” and “Move a task to Queue when it is ready to start.”

## 7. New Task sheet — `mac-05-new-task-sheet`
- Sheet attached to the main window (⌘N anywhere). Fields: project pull-down (neutral folder when an icon is shown), "What should be built" (multiline, initially focused), optional title under **Set a title yourself**, Attachments (tiles + dashed add area; drag-and-drop, paste; milestone 6).
- A nonblank brief is required. Save and open the task immediately with the user title or a locally shortened first line/sentence (at most 80 characters). Do not wait for Codex or scheduler work to dismiss the sheet. Refine an automatic title once in the background using an available economical model at its lowest supported reasoning effort; keep the local title if unavailable or unsuccessful. Manual titles/edits take precedence. Naming never starts a coding task or creates its worktree/session; Add to queue schedules coding independently. No model requests while typing.
- The task brief has a visible **Edit** action. **Task › Edit Task…** (⇧⌘E) and board/list context menus open the same native editor for title, brief and proof choice. Save Changes (Return) persists the draft; Cancel (Escape) discards it. Manual titles are never automatically replaced. Title-only changes preserve execution, proof, worktree branch and PR title.
- Editing the brief/proof before work starts preserves Backlog/Queue and does not dispatch it. For started work, Save pauses and stops the worker, returns it to Queue for replanning (Backlog stays Backlog), supersedes pending questions and old plan approvals, and invalidates previous proof. The user resumes explicitly; the same Codex thread and worktree continue with the updated brief. The editor explains this before saving. In PR, Merged and Canceled tasks allow title-only edits; the core rechecks state on Save.
- Footer: "Agents only pick up tasks in Queue." · **Cancel** (esc) · **Add to queue** · **Add to Backlog** (primary, ↩).

## 8. Project instructions — `mac-06-project-instructions`
- Toolbar: "Instructions" + "Every agent in <project> follows these"; More (Export to repository… v3, Reveal data folder).
- Large text editor (markdown, 14 pt, 22 pt line height). Autosaves 1 s after typing stops; "Saved" appears in the caption.
- Caption: "Applies to the project chat and every task agent. Stored in Build Mate on this Mac, not in the repository; running agents pick up changes on their next turn."
- **Agents also follow**: `AGENTS.md` in the repository (line count, **Open**; row hidden if absent) and **Instructions for all projects** (Settings › Instructions, **Edit…**). Footnote: project instructions win on conflict.

## 9. Task view (shared layout)
Designs: `mac-07` to `mac-10`. Toolbar (floating over content): Back/Forward group, task title + number; right: **Pause** (⌘.), **Open in <editor>** pull-down (⌘O opens default; menu lists installed editors with real app icons, Terminal ⌃⌘T, Show in Finder ⌥⌘R, Choose Default Editor…), Inspector + More group.

Left: the session transcript (same components as the chat) with the task's **brief** as the first user message (with attachments), activity rows, agent messages, screenshots, questions, events. Composer: attach, "Message the agent", send.

Right inspector: **Status** heading above the road-to-merge checklist (vertical, five steps, sub-items for Proof), then state-specific sections, then an optional footer with the primary action. Use “Status” for the checklist's accessibility label too.

Whenever a worktree path is present, show small Terminal and Finder icon buttons beside the **Worktree** heading. Terminal opens a new shell at that folder; Finder opens the folder. Give each button an accessible label and tooltip. If the worktree has been removed, show an explanatory error rather than opening another location.

### 9a. Needs Clarification — `mac-07-task-needs-clarification`
- Question cards (purple tint border): question text + answer chips; free-text via composer. Answering all blocking questions resumes the agent.
- Inspector: Status (Clarified = needs you, "2 questions · waiting 8 min"), Brief (text + attachments). Footer: **Let the agent decide** (agent proceeds with its stated defaults; confirmation popover lists them).

### 9b. Building — `mac-08-task-building`
- Live status line at the end of the transcript ("● Editing docs/api/audit.md…").
- Inspector: Status (Built = current, "Working · 14 min"; Proof sub-items unchecked), **Worktree** (path, **Open in <editor>**, **Terminal**), Brief.
- The design shows the Open-in menu expanded for reference.

### 9c. Human review — `mac-09-task-human-review`
- Display the task status as **Awaiting human review** in state labels, headings and transition events. The Status checklist retains **Human review** as the name of its review stage, including after completion.
- Inspector: Status (Human review = current), **Recording** (plays inline; click for a larger player window), **Try it yourself**: **Run locally** (primary, starts the preview and opens the browser), **Open in <editor>**, **Terminal**; **Changes** row (files · +/−; opens a changes sheet with the per-file list and "Open in <editor>"). Review feedback is sent through the chat composer and automatically returns the task to Building with fresh proof required. Footer: **Open Pull Request** (primary, with the host mark).

### 9d. In PR — `mac-10-task-in-pr`
- Transcript shows autonomous fixes as activity rows ("Fixed a failing lint check · pushed 3f2a91c", "Addressed 2 review comments from Sam") and decision questions.
- Inspector: Status (Merged = needs you or current), **Stack** (vertical: this PR → merged base PR(s) → main, with a caption when a rebase happened), **Pull request on GitHub/Bitbucket** (Checks, Approvals, Comments rows, each opening detail), watch explainer ("The agent watches for failed builds and review comments… only asks you when it needs a decision"). Footer: **View on GitHub / View on Bitbucket** (host mark).

## 10. Menu bar extra — `mac-11-menu-bar-extra`
- `MenuBarExtra` with window style, 340 pt wide, glass.
- Header: "Build Mate", "N building", **Pause All**, **New Task**.
- **Needs you** list (dot, title, short status: "2 questions", "Input", "Approve plan", "Human review"), **Building** list (turn progress or "Paused"). Rows open the task in the main window.
- Footer: "3 in PR · 1 retrying", **Open Build Mate**.
- Menu bar icon: template image; shows a small dot when anything needs the user.

## 11. Settings — `mac-12-settings-general`, `mac-13-settings-remote`
Standard Settings window with toolbar tabs: **General**, **Hooks**, **Instructions**, **Remote** (v2). Settings apply immediately (no Save button).
- **General** (per project where noted; the window shows a project picker in v1 when more than one project exists — not drawn): Tasks (Built-in; Linear/Jira v3), Open code in (editor), When work is split into tasks (One PR per task, stacked / One PR v1.1), Agents at once (stepper), Turns per task (stepper), **Ask me before**: Starting to build (off), Opening a pull request (on), Merging (off); **Advanced** (timeouts, retries, heavy-step limit, network access, branch prefix, PR footer, proof in PR description). Footnote: "Stored in Build Mate on this Mac, not in the repository."
- **Hooks** (not drawn): per project: After create, Before run, After run, Before remove (multiline shell fields with timeouts), Preview command + port variable + ready path, Checks (list of name + command + required), Recording (command or agent-driven, required). Editing a hook requires confirmation ("Hooks run as you on this Mac").
- **Instructions**: global instructions editor (same component as project instructions).
- **Remote** (v2): Allow remote control, Keep this Mac awake while agents work, Paired devices (with Remove), Pair a Device… (QR sheet), privacy footnote.

## 12. Add Project (not drawn — design with the New Task sheet style)
Sheet with native **Add Existing / Create New** segmented choice. Add Existing: choose a local repository (including local-only repositories with an initial commit), detected host and remote (GitHub or Bitbucket Cloud with mark), default branch, CLI status ("gh signed in as …" / "Set up Bitbucket in TWG…" with a button that opens Terminal with `twg setup bitbucket`), optional quick setup (preview command, checks). Primary: **Add Project**.

Create New: choose a new or empty folder, or type its full path (the parent must exist). The native folder panel permits creating a folder. **Create Project** runs `git init` on `main` and makes an empty initial commit so worktrees can branch immediately. Use the folder name as the project name. No starter files or remote are created. Reject nonempty folders and locations inside existing Git repositories before mutation. Failed creation preserves the folder; do not remove user files. The operation shows progress and prevents duplicate submission.

Local-only projects run tasks and collect proof without a hosting CLI. They stop at Human review with changes committed in the app-owned task worktree; publishing, local merge and PR actions are not implemented in this follow-up.

## 13. States not drawn (build to these rules)
- **Usage meter** (sidebar footer and menu bar): thin bar + "62% left · resets 16:40"; turns orange under 25 %, red under the hold threshold, with "New tasks on hold" and a Resume Anyway action.
- **Paused banner**: when everything is paused, a glass banner under the toolbar in every window: "All agents paused" · **Resume All**.
- **Errors**: CLI not signed in, repo missing, Codex unavailable, worktree conflict. Show inline in Needs You as a "Fix" section with one clear action each.
- **Loading**: skeleton rows in lists; never block the whole window.
- **First run**: welcome (what Build Mate does in three lines), sign in to Codex check, Add Project.

## 14. Menus and keyboard
| Command | Shortcut |
|---|---|
| New Task | ⌘N |
| New Project… | ⇧⌘N |
| Needs You / Chat / Backlog / Tasks / Instructions | ⌘1 … ⌘5 |
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

Menu bar menus: Build Mate, File (New Task, New Project, Close), Edit, View (Needs You, Chat, Backlog, Tasks, Instructions, as List/Board, Show Sidebar/Inspector), Task (Pause, Open in…, Move to Backlog, Cancel Task…), Window, Help. Every toolbar and context-menu action MUST be reachable from the menu bar.

## Milestone 3 implementation boundary

The native shell implements the sidebar, Add Project, Needs You summary, five-column board, grouped task list, persisted task transcript and inspector. A minimal task-entry sheet and question/plan actions are available to exercise the core. Full New Task attachments, editable instructions and project chat remain milestone 6; lifecycle review controls remain milestones 4–5. Native toolbar geometry and sidebar selection follow macOS controls. See 07 for validation status and 08 for setup assumptions.

Task proof: **Automatic** lets the agent choose checks and visual recording as appropriate to the task and brief. New Task also offers **Checks only** and **Checks + recording**; the inspector shows the choice, evidence rationale and whether recording was required. Missing recording configuration does not block Add to queue or Move to Queue: evidence is proposed and checked before Human review. Bitbucket starts stay disabled until its provider is verified.

The composer distinguishes **Send answer**, **Send message** (an active Codex turn), **Send message** (awaiting human review; returns to Building and requires fresh proof), and **Save message** (other states with no active turn). Saving persists the message for the next run and never starts or resumes a task. Successful submission confirms whether the message was sent or saved. Return submits; ⌘Return is also available. Draft and delivery status reset when changing tasks.

Retained retry diagnostics do not appear as a current Fix item while a recovered turn is running or waiting for a question/approval.

Queue ordering: picking up a Backlog row or Queue card/list row shows a raised native drag preview and fades its placeholder. As the pointer crosses another item's midpoint, surrounding items smoothly shift to preview the new order. Save priority only on a valid drop; Escape or dropping outside the group restores the original order. Reordering stays within a project and state; it never moves tasks into execution or interrupts an existing run. Top is highest priority. Context-menu Move Earlier/Later, accessibility actions, and Task menu ⌃⌘↑/↓ provide alternatives. Search preserves the full queue ordering. Reduce Motion disables the lift scaling and positional animations.

Usage UI follow-up: the sidebar shows the most constrained Codex account window, a remaining-percentage bar and reset time. Its popover lists every reported bucket/window, shared-account explanation, last refresh, errors and Refresh. Refresh on startup/every minute and consume live account notifications; an account-only app-server process creates no agent thread. Unknown windows/resets remain unavailable, never zero or invented. Failed refreshes retain clearly labelled last-known values. This delivery is informational: automatic 15% holds, Resume Anyway, threshold settings and menu-bar usage remain milestone 7. The percentage bar turns orange below 25% and red below 15% as a warning only.

Outside human review, the inactive task composer hint reads “Messages are saved for when work resumes.” This describes delivery before sending; the post-send status still confirms the actual result.

## Task identity in the interface (2026-09-26)

Use task titles, with project names where needed, to identify tasks. Hide internal task numbers from board cards, grouped lists, task-window subtitles, Needs You and their spoken accessibility labels; omit the former number column entirely. Dependency labels read “Waits on <task title>”. This supersedes numbered-task examples above. Keep task numbers internally for persistence, agent references, search compatibility and automation identifiers. Preserve real pull request numbers and original conversation text.


## Milestone 4 implemented lifecycle controls

- New Task includes **Plan approval**: project default, ask before building, or build automatically. The override is stored atomically with task creation. A pending plan is readable in the inspector and approved there or from Task › Approve Plan.
- **Let the Agent Decide…** shows the agent's explicit suggestions for unresolved blocking questions in a confirmation sheet. Accepting records `agentDefault`; tasks remain paused if previously paused. Questions without suggestions require a normal answer.
- Human review shows the proof summary/rationale, check results with durations and clickable logs, an inline AVKit recording with native controls, Expand Recording in a separate window, and before/after screenshots that expand in a sheet. **Changes** shows per-file additions/deletions and Open File.
- **Chat review feedback** replaces Send Back. A non-empty message while awaiting human review automatically returns to Building, preserves the thread/branch/approved plan and invalidates proof. Paused task/project/global work stays paused; otherwise the scheduler resumes it when a slot is available. The composer explains this before sending. **Open Pull Request** uses the existing basic GitHub path and rechecks the reviewed commit and clean worktree. Local projects retain their committed worktree for editor/Terminal use. Full Bitbucket, stacking/watch/merge controls remain milestone 5.
- **Run locally** first offers project preview configuration if missing; saving never starts a process. Starting, ready, stopped and failed states expose Stop, redacted output and configuration. Ready opens the browser; later clicks reuse it. CLI/native projects can open their worktree in Terminal/editor instead.
- **Open in…** uses installed Cursor, VS Code and Xcode with their app icons; offers Terminal, installed iTerm/Ghostty, Finder, and per-project default editor. Task actions target its worktree; project actions target the clone. Missing/removed paths produce an actionable error. Shortcuts: ⌘O, ⌃⌘T, ⌥⌘R. Preview, changes, suggestions, plan approval, PR opening and recording expansion are also in the Task menu. All added buttons have help text.


Editor-icon refinement (2026-09-27): the Open in control shows only a centred 16 pt app icon and dropdown chevron; the editor name remains in its tooltip and accessibility label. Its dropdown uses the real installed app icons for editors, Terminal/iTerm/Ghostty and Finder. Retain the existing Default Editor submenu, with a checkmark on the selected editor; choosing it remains scoped to the current project. Use the native AppKit split button to explicitly preserve identifying menu images on macOS 27; macOS 26 uses its normal menu images. Tooltips and keyboard selection remain available.


## Project chat delivery brought forward (2026-09-27)

The Chat page now supports persistent text conversations, streamed agent bubbles, expandable inspection output, inline questions/answers, selectable proposals, Add to queue/Add N to Backlog, and live task links in the From this chat inspector. Proposal dependencies are shown by task title. Unselected tasks are not created; dependencies of selected tasks must also be selected. Dismiss makes a proposal inactive. Natural-language routing supports mixed destinations through the project agent. Backlog task details, row context menus and the Task menu expose Refine with Agent, opening project chat without starting coding. Project questions appear in Needs You and the Chat badge.

The glass composer uses the existing neutral bubble palette and system controls; ⌘Return/Return sends, Stop cancels, Retry continues an interrupted or failed conversation. Each project keeps its unsent draft while navigating. No additional messages are submitted during an active response except answers to its question. Project/global pause queues a message until resumed. The inspector shows only the latest chat-created task with its live state and dependencies. Project checkout/branch information and Open Tasks stay pinned in a separate bottom section; older tasks remain available on the task board and in Backlog.

This pulls forward text project chat and backlog refinement, not all of milestone 6: image/video attachment entry and instruction editing remain separate remaining work. Proposal Ship as controls remain hidden until the related SCM capability exists. Spoken VoiceOver and reduced-transparency validation are not inferred from accessibility labels alone.


### Screenshot and file attachments (2026-09-27)

Both project and task composers offer a paperclip for the native multiple-file picker and a camera menu with **Capture Window…** and **Capture Area…**. Capture uses macOS's interactive selector: click a window or draw a rectangle; Escape cancels. The app temporarily hides during capture and returns with the image attached to the draft. macOS may request Screen Recording access. Capture never sends automatically.

Drop files or image data anywhere in the chat. Draft attachments show thumbnails/filenames, Preview and Remove actions. Files can be sent without message text (a question still needs a valid answer). Sent images appear in the conversation; clicking an attachment opens native Quick Look. Task brief attachments inherited from project chat are visible in task details. All controls have tooltips and accessibility names. Attachment bytes are cleaned up on merge as described in 02; removed files retain a filename placeholder.

This implements image/file attachments; video frame extraction and clipboard image paste remain separate from the delivered drag/drop, picker and screenshot entry points.

The ordinary project composer has no explanatory caption (user preference); retain the answer hint only while a clarification question is pending.

### Milestone 6 editor and attachment completion

Instructions are editable in the project sidebar and Settings › Instructions, autosaved after one second and flushed on navigation. New Task includes the shared attachment controls and drop/paste support. Chat and New Task accept clipboard images/files with ⌘V. Videos show a thumbnail and supply six chronological frames to the agent; audio is not automatically transcribed.

### Milestone 7 controls

Settings (⌘,) has General, Hooks and Instructions tabs. Global concurrency, heavy-step limits and usage threshold are editable; per-project settings cover editor, turns, plan approval, timeouts, network and branch prefix. Hooks includes workspace hooks, local preview, checks and visual-proof commands, with an explicit command-editing confirmation. Incomplete checks stay drafts. PR creation remains explicit and automatic merging is unavailable pending milestone 5.

Menu-bar extra shows attention items, building tasks/project chats, paused state and account usage. Open and notification actions reuse the main window. Notifications are enabled from Settings and grouped by project; Open routes directly to the task or chat. Closing the window keeps the menu-bar app active. Quitting with active agents asks before stopping them.

Queue cards show “Waiting for usage” while held. The usage popover offers Resume Anyway. Merged is always a board column. Task menu includes Move to Backlog and Cancel Task, retaining history/worktrees. ⌃⌘S toggles the sidebar.

Backlog’s Select Tasks action enables native Command-click/Shift-click multiselection. Move to Queue (⌘Return) queues the selection together; ordinary row clicks still open the task when selection mode is off.

While an agent responds, project and task chats show a compact Messages-style three-dot speech bubble in the agent bubble colour, instead of a spinner/status sentence. Waiting for input, queued and paused states retain explicit labels. The bubble is static with Reduce Motion enabled.

### Conversation model and effort (2026-09-27)

Task and project chat toolbars show the selected model and effort. The native popover provides model/effort pickers, supported choices from Codex, refresh, errors, tooltips and accessibility labels. Choices can be changed in any task state or during a response, persist across restart, and apply at the next turn without discarding history or interrupting work. A pending-change explanation appears when the current turn uses a different choice. Project chat defaults to Astra High; tasks inherit project/Codex defaults until changed. An unavailable configured model remains visible with guidance to choose another or update Codex; no silent fallback.
