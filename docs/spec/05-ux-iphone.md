# 05 · iPhone UX (v2)

Designs: `docs/design/png/{light,dark}/iphone-pro-*.png` and `iphone-duo-*.png`. The iPhone app is a remote control for the Mac helper (02 §13). It never runs agents.

Devices: **iPhone Pro** (6.3-inch class, 402×874 pt) and **iPhone Duo** (foldable: outer display ~464×676 pt portrait, inner ~952×652 pt landscape — sizes are estimates; confirm with Apple's Duo guidance and Xcode device support). Use size classes and the fold/unfold scene updates, not device checks.

## Navigation
- Tab bar (iOS 26 floating glass): **Needs You** (badge = total items) and **Projects**. Actions (New Task, Pause All) live in the top bar, never in the tab bar.
- Host chip at top-left of Needs You and Projects: "● Studio · 4 building" (connection status; tap for host details and switching hosts).
- A project opens to its Chat, with a top-bar button to Tasks, plus Backlog and Instructions entries.

## Screens
| Design | Screen | Notes |
|---|---|---|
| `iphone-pro-01-needs-you` | Needs You | Large title. Sections Questions, Approvals, Ready for human review (recording thumbnails), Building. Top bar: Pause All, New Task. List rows 17 pt regular + 15 pt secondary, inset grouped with 26 pt radius. |
| `iphone-pro-02-projects` | Projects | Rows with host mark tile (GitHub/Bitbucket), "4 building · 5 need you". Footer: "Projects live on your Mac. Add one there to see it here." |
| `iphone-pro-03-project-chat` | Project chat | Same proposal card as Mac: round checkmarks, "after 1", **Ship as** row, **Start Now** / **Add to Backlog**. Composer: attach, text, dictation. |
| `iphone-pro-04-backlog` | Backlog | Swipe a row left: **Start** (moves to Todo) and **Delete**. Tap to edit (same fields as Mac). |
| `iphone-pro-05-instructions` | Instructions | Editable text; footnote about AGENTS.md. |
| `iphone-pro-06-answer-questions` | Answer | Road to merge caption, agent message, question cards with 44 pt answer chips, composer with dictation. |
| `iphone-pro-07-human-review` | Human review | Recording (full width), **Open Preview** (opens the Mac's preview over the private network), checks summary, agent summary, **Send Back…**, **Open Pull Request** (host mark). |
| `iphone-duo-01..03` | Closed (outer display) | Same as Pro screens, fitted to the outer display. |
| `iphone-duo-04-open-tasks` | Unfolded: Tasks | Board with 5 columns (horizontal scroll), project picker "acme/web ▾" in the header. |
| `iphone-duo-05-open-human-review` | Unfolded: Review | Split view: Needs You list on the left, review on the right. |

Rules:
- Touch targets ≥ 44 pt; Dynamic Type up to AX5 (rows grow, chips wrap).
- Destructive and outward actions (Open Pull Request, Merge, Delete) require Face ID/Touch ID confirmation.
- Notifications: actionable (answer options, Approve Plan). Delivered through CloudKit subscriptions.
- Offline/unreachable host: banner "Studio is offline · Last seen 10 min ago"; show cached data read-only.
