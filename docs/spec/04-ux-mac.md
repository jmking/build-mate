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
├─ Sheets: New Task, Add Project, Send Back, Delete confirmations
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
  - **Proposal card** (from `propose_tasks`): header "3 tasks for acme/web · each gets its own agent and worktree"; one row per task with a checkbox (checked by default), number, title, "after N" dependency chip, one-line plan; footer: **Ship as** pull-down ("3 PRs, #2 stacked on #1" / "One PR (v1.1)"), **Start Now** (secondary), **Add N to Backlog** (primary, default). Unchecking a task excludes it. After creation the card collapses to a summary with links to the tasks.
  - Task chips after creation: glass capsules "● #427 Building" that open the task.
- Composer (floating glass, bottom): attach (paperclip; also drag-and-drop and paste images/video), text field "Describe what you want built…", send (accent circle, ⌘↩ or ↩).
- Natural-language routing: "start now", "go straight to Queue" → Start Now; "backlog the rest" etc. The agent echoes the outcome as an event.
- Inspector: **From this chat** (tasks created here, live state, "Backlog · waiting for you to refine", "then waits on #427") and **Project** (checkout path, branch, agent/model, host mark + remote slug), footer **Open Tasks**.

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
- Card (12 pt radius): optional attachment preview (image, or video with glass play button), title (2 lines max), number, attachment count, status on the right (coloured dot + text, e.g. "2 questions", "Approve plan", "Paused", "Retry in 0:31", "Proof complete", "Fixing build", "1 of 2 approvals"), optional "Waits on #427" chip. Do not show segmented progress bars on board or Needs You cards; the labelled Road to merge checklist lives in task details.
- Drag and drop reorders tasks within Backlog or Queue; it does not change task state. Use explicit actions to move tasks between Backlog and Queue. Other state changes are agent-driven or use the task's explicit review actions.
- Context menu: Open, Open in <editor>, Pause/Resume, Move to Backlog, Cancel Task…, Copy Link.
- **List view** (not drawn): a table grouped by state with the same columns of data; filter by state including Merged.

## 7. New Task sheet — `mac-05-new-task-sheet`
- Sheet attached to the main window (⌘N anywhere). Fields: project pull-down (neutral folder when an icon is shown), "What should be built" (multiline, initially focused), optional title under **Set a title yourself**, Attachments (tiles + dashed add area; drag-and-drop, paste; milestone 6).
- A nonblank brief is required. Save and open the task immediately with the user title or a locally shortened first line/sentence (at most 80 characters). Do not wait for Codex or scheduler work to dismiss the sheet. Refine an automatic title once in the background using an available economical model at its lowest supported reasoning effort; keep the local title if unavailable or unsuccessful. Manual titles/edits take precedence. Naming never starts a coding task or creates its worktree/session; Start Now schedules coding independently. No model requests while typing.
- The task brief has a visible **Edit** action. **Task › Edit Task…** (⇧⌘E) and board/list context menus open the same native editor for title, brief and proof choice. Save Changes (Return) persists the draft; Cancel (Escape) discards it. Manual titles are never automatically replaced. Title-only changes preserve execution, proof, worktree branch and PR title.
- Editing the brief/proof before work starts preserves Backlog/Queue and does not dispatch it. For started work, Save pauses and stops the worker, returns it to Queue for replanning (Backlog stays Backlog), supersedes pending questions and old plan approvals, and invalidates previous proof. The user resumes explicitly; the same Codex thread and worktree continue with the updated brief. The editor explains this before saving. In PR, Merged and Canceled tasks allow title-only edits; the core rechecks state on Save.
- Footer: "Agents only pick up tasks in Queue." · **Cancel** (esc) · **Start Now** · **Add to Backlog** (primary, ↩).

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
- Inspector: Road to merge (Clarified = needs you, "2 questions · waiting 8 min"), Brief (text + attachments). Footer: **Let the agent decide** (agent proceeds with its stated defaults; confirmation popover lists them).

### 9b. Building — `mac-08-task-building`
- Live status line at the end of the transcript ("● Editing docs/api/audit.md…").
- Inspector: Road to merge (Built = current, "Working · 14 min"; Proof sub-items unchecked), **Worktree** (path, **Open in <editor>**, **Terminal**), Brief.
- The design shows the Open-in menu expanded for reference.

### 9c. Human review — `mac-09-task-human-review`
- Display the task status as **Awaiting human review** in state labels, headings and transition events. The Road to merge checklist retains **Human review** as the name of its review stage, including after completion.
- Inspector: Road to merge (Human review = current), **Recording** (plays inline; click for a larger player window), **Try it yourself**: **Run locally** (primary, starts the preview and opens the browser), **Open in <editor>**, **Terminal**; **Changes** row (files · +/−; opens a changes sheet with the per-file list and "Open in <editor>"). Footer: **Send back…** (sheet with a note field; returns to Building) and **Open Pull Request** (primary, with the host mark).

### 9d. In PR — `mac-10-task-in-pr`
- Transcript shows autonomous fixes as activity rows ("Fixed a failing lint check · pushed 3f2a91c", "Addressed 2 review comments from Sam") and decision questions.
- Inspector: Road to merge (Merged = needs you or current), **Stack** (vertical: this PR → merged base PR(s) → main, with a caption when a rebase happened), **Pull request on GitHub/Bitbucket** (Checks, Approvals, Comments rows, each opening detail), watch explainer ("The agent watches for failed builds and review comments… only asks you when it needs a decision"). Footer: **View on GitHub / View on Bitbucket** (host mark).

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

Task proof: **Automatic** lets the agent choose checks and visual recording as appropriate to the task and brief. New Task also offers **Checks only** and **Checks + recording**; the inspector shows the choice, evidence rationale and whether recording was required. Missing recording configuration does not block Start Now or Move to Queue: evidence is proposed and checked before Human review. Bitbucket starts stay disabled until its provider is verified.

The composer distinguishes **Send answer**, **Send message** (an active Codex turn), and **Save message** (no active turn). Saving persists the message for the next run and never starts or resumes a task. Successful submission confirms whether the message was sent or saved. Return submits; ⌘Return is also available. Draft and delivery status reset when changing tasks.

Retained retry diagnostics do not appear as a current Fix item while a recovered turn is running or waiting for a question/approval.

Queue ordering: drag Backlog rows or Queue cards/list rows onto the upper/lower half of another item to place them before/after it. Reordering stays within a project and state; it never moves tasks into execution or interrupts an existing run. Top is highest priority. Context-menu Move Earlier/Later, accessibility actions, and Task menu ⌃⌘↑/↓ provide alternatives. Search preserves the full queue ordering.

Usage UI follow-up: the sidebar shows the most constrained Codex account window, a remaining-percentage bar and reset time. Its popover lists every reported bucket/window, shared-account explanation, last refresh, errors and Refresh. Refresh on startup/every minute and consume live account notifications; an account-only app-server process creates no agent thread. Unknown windows/resets remain unavailable, never zero or invented. Failed refreshes retain clearly labelled last-known values. This delivery is informational: automatic 15% holds, Resume Anyway, threshold settings and menu-bar usage remain milestone 7. The percentage bar turns orange below 25% and red below 15% as a warning only.

The inactive task composer hint reads “Messages are saved for when work resumes.” This describes delivery before sending; the post-send status still confirms the actual result.

## Task identity in the interface (2026-09-26)

Use task titles, with project names where needed, to identify tasks. Hide internal task numbers from board cards, grouped lists, task-window subtitles, Needs You and their spoken accessibility labels; omit the former number column entirely. Dependency labels read “Waits on <task title>”. This supersedes numbered-task examples above. Keep task numbers internally for persistence, agent references, search compatibility and automation identifiers. Preserve real pull request numbers and original conversation text.
