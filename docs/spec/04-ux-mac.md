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
  - **Projects** heading with **+** (Add Project). Each project row: disclosure chevron, host mark (GitHub mark in label colour, Bitbucket mark in Bitbucket blue), name, optional pause glyph (project paused), neutral badge = items needing the user in that project.
  - Expanded project children (indented): **Chat**, **Backlog** (plain count), **Tasks** (badge = needs-you count), **Instructions**.
  - Selection: neutral translucent fill, regular weight text, accent-tinted SF Symbols (HIG sidebar).
  - Footer: "N of M agents busy" (tabular numerals), usage meter (see §13), **Pause All** (⌥⌘P), **Settings** (⌘,).
- **Toolbar** (unified, 52–56 pt): title (15 pt semibold) and optional subtitle on the left; grouped Liquid Glass controls on the right. Related controls share one capsule (for example Search + New Task; Back + Forward; Inspector + More).
- **Content**: white (light) / window background (dark). Task views and the project chat let content scroll under the toolbar with a soft scroll-edge fade instead of a divider.
- **Inspector** (task views and chat, 340 pt, toggle ⌥⌘I): slightly raised background, content starts below the toolbar.

## 3. Needs You (home) — `mac-01-needs-you`
**Purpose:** everything waiting on the user across all projects, answerable in place.
- Toolbar: "Needs You" + "7 across 2 projects"; Search, New Task.
- Sections, in this order, only when non-empty:
  1. **Questions**: row = status dot (needs-you purple), task title, project · #number, the question text, answer chips, **Open**. Clicking a chip answers immediately (optimistic, undo toast for 5 s). If the question allows free text, **Open** focuses the task composer.
  2. **Approvals**: plan approvals and merge approvals. Row = title, project · #number · reason ("you asked to approve the plan"), plan summary, **View Plan** (opens the task scrolled to the plan) and **Approve Plan** (or **Merge**).
  3. **Decisions in PR**: blocking questions raised while a task is In PR (same row as Questions).
  4. **Ready for human review**: recording thumbnail (glass play button), title, project · #number · recording length · checks, Road-to-merge bar, **Open Preview**, **Review** (opens the task view).
- Empty state: large SF Symbol `checkmark.circle`, "Nothing needs you", secondary line "Agents are working on N tasks." with a link to the busiest project.
- Updates live; newly arrived items highlight briefly (respect Reduce Motion).

## 4. Project chat — `mac-02-project-chat`
**Purpose:** talk to the project agent; turn intent into tasks.
- Toolbar: "Chat" + project name; **Open in <editor>** (opens the main checkout), Inspector toggle.
- Transcript (max width 720, centered):
  - User messages: right-aligned grey bubbles with attachments (images/video thumbnails, 220×140).
  - Project agent messages: left-aligned plain text with "Project agent · time".
  - Activity rows: collapsed pill "Read 22 files in reports/ and exports/ · 2 min" with chevron; expands to the raw tool list.
  - Events: centered small grey line with hairlines ("#427 and #428 in Todo · #429 in Backlog").
  - **Proposal card** (from `propose_tasks`): header "3 tasks for acme/web · each gets its own agent and worktree"; one row per task with a checkbox (checked by default), number, title, "after N" dependency chip, one-line plan; footer: **Ship as** pull-down ("3 PRs, #2 stacked on #1" / "One PR (v1.1)"), **Start Now** (secondary), **Add N to Backlog** (primary, default). Unchecking a task excludes it. After creation the card collapses to a summary with links to the tasks.
  - Task chips after creation: glass capsules "● #427 Building" that open the task.
- Composer (floating glass, bottom): attach (paperclip; also drag-and-drop and paste images/video), text field "Describe what you want built…", send (accent circle, ⌘↩ or ↩).
- Natural-language routing: "start now", "go straight to Todo" → Start Now; "backlog the rest" etc. The agent echoes the outcome as an event.
- Inspector: **From this chat** (tasks created here, live state, "Backlog · waiting for you to refine", "then waits on #427") and **Project** (checkout path, branch, agent/model, host mark + remote slug), footer **Open Tasks**.

## 5. Backlog — `mac-03-backlog`
**Purpose:** refine tasks before any agent starts them.
- Toolbar: "Backlog" + "4 tasks · agents won't start these until you move them to Todo"; Search, New Task.
- Left list (420 pt): drag handle, title, one-line description, meta ("From chat · today", "2 attachments", "Waits on #412"), number. Drag to reorder (sets start order). Multi-select with ⇧/⌘; **Move to Todo** acts on the selection (⌘↩).
- Right editor: "#429 · Backlog · created from Chat at 09:11"; title (large inline field); Description (text editor, markdown); Attachments (tiles + add); settings list: **Depends on** (pull-down, multiple), **Ship as** (Its own PR / stacked / one PR v1.1), **Ask me before building** (Use project setting / On / Off). Footer: **Delete…** (destructive, confirm), **Refine with Agent** (sparkles; the project agent rewrites the description and asks questions in the chat), **Move to Todo** (primary).
- Empty state: "Backlog is empty" + "Tasks you add from the chat land here."

## 6. Tasks board — `mac-04-board`
- Toolbar: "Tasks"; **Pause Project**; List/Board segmented control (⌘L toggles); Search; New Task (⌘N).
- Columns (left to right): **Todo**, **Needs Clarification**, **Building**, **Human review**, **In PR**. Done is reachable from the list view filter and search (not a column). Column: 20 pt radius, 8 pt padding, header icon + name + count; Todo header has **+**.
- Todo column starts with a dashed **Backlog · N** row linking to Backlog.
- Card (12 pt radius): optional attachment preview (image, or video with glass play button), title (2 lines max), number, attachment count, status on the right (coloured dot + text, e.g. "2 questions", "Approve plan", "Paused", "Retry in 0:31", "Proof complete", "Fixing build", "1 of 2 approvals"), optional "Waits on #427" chip, and the 5-segment **Road to merge** bar (not shown for Todo cards without progress).
- Drag and drop: Backlog ↔ Todo, and Todo reorder, are allowed; other moves are agent-driven, except dragging a card to the Backlog link (moves it back and stops its session after confirmation).
- Context menu: Open, Open in <editor>, Pause/Resume, Move to Backlog, Cancel Task…, Copy Link.
- **List view** (not drawn): a table grouped by state with the same columns of data; filter by state including Done.

## 7. New Task sheet — `mac-05-new-task-sheet`
- Sheet attached to the main window (⌘N anywhere). Fields: project pull-down (host mark), "What should be built" (multiline, initially focused), optional title under **Set a title yourself**, Attachments (tiles + dashed add area; drag-and-drop, paste; milestone 6).
- A nonblank brief is required. On creation, Codex generates a concise descriptive title from the brief unless the user supplies one. Show progress, prevent duplicate submission and allow Cancel while naming. If generation fails or times out, use the first line/sentence of the brief, shortened to 80 characters; saving must still work. Naming does not start the coding task or create a worktree, including for Backlog. No model requests while typing.
- The task brief's **Rename task** button opens a native sheet with Save (Return) and Cancel (Escape). Manual titles are never automatically replaced. Renaming does not change the description, state, existing worktree branch or an existing PR title.
- Footer: "Agents only pick up tasks in Todo." · **Cancel** (esc) · **Start Now** · **Add to Backlog** (primary, ↩).

## 8. Project instructions — `mac-06-project-instructions`
- Toolbar: "Instructions" + "Every agent in <project> follows these"; More (Export to repository… v3, Reveal data folder).
- Large text editor (markdown, 14 pt, 22 pt line height). Autosaves 1 s after typing stops; "Saved" appears in the caption.
- Caption: "Applies to the project chat and every task agent. Stored in Build Mate on this Mac, not in the repository; running agents pick up changes on their next turn."
- **Agents also follow**: `AGENTS.md` in the repository (line count, **Open**; row hidden if absent) and **Instructions for all projects** (Settings › Instructions, **Edit…**). Footnote: project instructions win on conflict.

## 9. Task view (shared layout)
Designs: `mac-07` to `mac-10`. Toolbar (floating over content): Back/Forward group, task title + number; right: **Pause** (⌘.), **Open in <editor>** pull-down (⌘O opens default; menu lists installed editors with real app icons, Terminal ⌃⌘T, Show in Finder ⌥⌘R, Choose Default Editor…), Inspector + More group.

Left: the session transcript (same components as the chat) with the task's **brief** as the first user message (with attachments), activity rows, agent messages, screenshots, questions, events. Composer: attach, "Message the agent", send.

Right inspector: **Road to merge** checklist (vertical, five steps, sub-items for Proof), then state-specific sections, then an optional footer with the primary action.

### 9a. Needs Clarification — `mac-07-task-needs-clarification`
- Question cards (purple tint border): question text + answer chips; free-text via composer. Answering all blocking questions resumes the agent.
- Inspector: Road to merge (Clarified = needs you, "2 questions · waiting 8 min"), Brief (text + attachments). Footer: **Let the agent decide** (agent proceeds with its stated defaults; confirmation popover lists them).

### 9b. Building — `mac-08-task-building`
- Live status line at the end of the transcript ("● Editing docs/api/audit.md…").
- Inspector: Road to merge (Built = current, "Working · 14 min"; Proof sub-items unchecked), **Worktree** (path, **Open in <editor>**, **Terminal**), Brief.
- The design shows the Open-in menu expanded for reference.

### 9c. Human review — `mac-09-task-human-review`
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
Sheet: choose a local clone (Open panel filtered to folders containing `.git`), detected host and remote (GitHub or Bitbucket Cloud with mark), default branch, CLI status ("gh signed in as …" / "Set up Bitbucket in TWG…" with a button that opens Terminal with `twg setup bitbucket`), optional quick setup (preview command, checks). Footnote: "Nothing is written to the repository." Primary: **Add Project**.

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

The native shell implements the sidebar, Add Project, Needs You summary, five-column board, grouped task list, persisted task transcript and inspector. A minimal task-entry sheet and question/plan actions are available to exercise the core. Full New Task attachments, backlog ordering (including board drag/drop), editable instructions and project chat remain milestone 6; lifecycle review controls remain milestones 4–5. Native toolbar geometry and sidebar selection follow macOS controls. See 07 for validation status and 08 for setup assumptions.

Milestone 3 run readiness: if required recording has no command, **Start Now** and **Move to Todo** are disabled with a visible explanation; saving to Backlog remains available. The core checks the same condition before dispatch, including tasks already in Todo. Proof setup UI arrives with lifecycle/settings work. Bitbucket starts stay disabled until its provider is verified.

The composer distinguishes **Send answer**, **Send message** (an active Codex turn), and **Save message** (no active turn). Saving persists the message for the next run and never starts or resumes a task. Successful submission confirms whether the message was sent or saved. Return submits; ⌘Return is also available. Draft and delivery status reset when changing tasks.

Retained retry diagnostics do not appear as a current Fix item while a recovered turn is running or waiting for a question/approval.
