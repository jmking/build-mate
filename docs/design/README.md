# Build Mate designs

Every designed screen in light and dark mode. PNGs are 2× renders of the HTML references.

- **PNG** (`png/light`, `png/dark`): what the screen should look like.
- **HTML** (`html/light`, `html/dark`): static references with exact sizes, spacing, radii and colours in inline styles. Open in a browser (Chrome renders the glass materials best). They use sample data.
- **Assets** (`assets/`): real app icons (Cursor, VS Code, Xcode, Terminal, Finder) exported from the installed apps, and the official GitHub and Bitbucket marks (SVG). At runtime, app icons come from `NSWorkspace`.
- **Build Mate app icon** ([source and previews](app-icon/README.md)): original structural M, packaged as a native Icon Composer document with light and dark appearances.

Mac screens are drawn as a 1440×900 window on a desktop wallpaper so the sidebar and toolbar glass can be seen; the wallpaper is not part of the app. iPhone screens are drawn at device size in points (Duo sizes are estimates).

The live, editable canvas these were exported from is a private claude.ai artifact ("Build Mate", Light and Dark pages); these files are the source of truth for implementation.

| Screen | PNG | HTML | Size (pt) | Spec |
|---|---|---|---|---|
| Needs You (home) | [light](png/light/mac-01-needs-you.png) · [dark](png/dark/mac-01-needs-you.png) | [light](html/light/mac-01-needs-you.html) · [dark](html/dark/mac-01-needs-you.html) | 1560×1000 | 04 §3 |
| Project chat | [light](png/light/mac-02-project-chat.png) · [dark](png/dark/mac-02-project-chat.png) | [light](html/light/mac-02-project-chat.html) · [dark](html/dark/mac-02-project-chat.html) | 1560×1000 | 04 §4 |
| Backlog | [light](png/light/mac-03-backlog.png) · [dark](png/dark/mac-03-backlog.png) | [light](html/light/mac-03-backlog.html) · [dark](html/dark/mac-03-backlog.html) | 1560×1000 | 04 §5 |
| Tasks board | [light](png/light/mac-04-board.png) · [dark](png/dark/mac-04-board.png) | [light](html/light/mac-04-board.html) · [dark](html/dark/mac-04-board.html) | 1560×1000 | 04 §6 |
| New Task sheet | [light](png/light/mac-05-new-task-sheet.png) · [dark](png/dark/mac-05-new-task-sheet.png) | [light](html/light/mac-05-new-task-sheet.html) · [dark](html/dark/mac-05-new-task-sheet.html) | 1560×1000 | 04 §7 |
| Project instructions | [light](png/light/mac-06-project-instructions.png) · [dark](png/dark/mac-06-project-instructions.png) | [light](html/light/mac-06-project-instructions.html) · [dark](html/dark/mac-06-project-instructions.html) | 1560×1000 | 04 §8 |
| Task · Needs Clarification | [light](png/light/mac-07-task-needs-clarification.png) · [dark](png/dark/mac-07-task-needs-clarification.png) | [light](html/light/mac-07-task-needs-clarification.html) · [dark](html/dark/mac-07-task-needs-clarification.html) | 1560×1000 | 04 §9a |
| Task · Building (Open-in menu shown open) | [light](png/light/mac-08-task-building.png) · [dark](png/dark/mac-08-task-building.png) | [light](html/light/mac-08-task-building.html) · [dark](html/dark/mac-08-task-building.html) | 1560×1000 | 04 §9b |
| Task · Human review | [light](png/light/mac-09-task-human-review.png) · [dark](png/dark/mac-09-task-human-review.png) | [light](html/light/mac-09-task-human-review.html) · [dark](html/dark/mac-09-task-human-review.html) | 1560×1000 | 04 §9c |
| Task · In PR | [light](png/light/mac-10-task-in-pr.png) · [dark](png/dark/mac-10-task-in-pr.png) | [light](html/light/mac-10-task-in-pr.html) · [dark](html/dark/mac-10-task-in-pr.html) | 1560×1000 | 04 §9d |
| Menu bar extra | [light](png/light/mac-11-menu-bar-extra.png) · [dark](png/dark/mac-11-menu-bar-extra.png) | [light](html/light/mac-11-menu-bar-extra.html) · [dark](html/dark/mac-11-menu-bar-extra.html) | 460×530 | 04 §10 |
| Settings · General | [light](png/light/mac-12-settings-general.png) · [dark](png/dark/mac-12-settings-general.png) | [light](html/light/mac-12-settings-general.html) · [dark](html/dark/mac-12-settings-general.html) | 760×800 | 04 §11 |
| Settings · Remote (v2) | [light](png/light/mac-13-settings-remote.png) · [dark](png/dark/mac-13-settings-remote.png) | [light](html/light/mac-13-settings-remote.html) · [dark](html/dark/mac-13-settings-remote.html) | 760×640 | 04 §11 |
| iPhone Pro · Needs You | [light](png/light/iphone-pro-01-needs-you.png) · [dark](png/dark/iphone-pro-01-needs-you.png) | [light](html/light/iphone-pro-01-needs-you.html) · [dark](html/dark/iphone-pro-01-needs-you.html) | 402×874 | 05 |
| iPhone Pro · Projects | [light](png/light/iphone-pro-02-projects.png) · [dark](png/dark/iphone-pro-02-projects.png) | [light](html/light/iphone-pro-02-projects.html) · [dark](html/dark/iphone-pro-02-projects.html) | 402×874 | 05 |
| iPhone Pro · Project chat | [light](png/light/iphone-pro-03-project-chat.png) · [dark](png/dark/iphone-pro-03-project-chat.png) | [light](html/light/iphone-pro-03-project-chat.html) · [dark](html/dark/iphone-pro-03-project-chat.html) | 402×874 | 05 |
| iPhone Pro · Backlog | [light](png/light/iphone-pro-04-backlog.png) · [dark](png/dark/iphone-pro-04-backlog.png) | [light](html/light/iphone-pro-04-backlog.html) · [dark](html/dark/iphone-pro-04-backlog.html) | 402×874 | 05 |
| iPhone Pro · Instructions | [light](png/light/iphone-pro-05-instructions.png) · [dark](png/dark/iphone-pro-05-instructions.png) | [light](html/light/iphone-pro-05-instructions.html) · [dark](html/dark/iphone-pro-05-instructions.html) | 402×874 | 05 |
| iPhone Pro · Answer | [light](png/light/iphone-pro-06-answer-questions.png) · [dark](png/dark/iphone-pro-06-answer-questions.png) | [light](html/light/iphone-pro-06-answer-questions.html) · [dark](html/dark/iphone-pro-06-answer-questions.html) | 402×874 | 05 |
| iPhone Pro · Human review | [light](png/light/iphone-pro-07-human-review.png) · [dark](png/dark/iphone-pro-07-human-review.png) | [light](html/light/iphone-pro-07-human-review.html) · [dark](html/dark/iphone-pro-07-human-review.html) | 402×874 | 05 |
| iPhone Duo closed · Needs You | [light](png/light/iphone-duo-01-closed-needs-you.png) · [dark](png/dark/iphone-duo-01-closed-needs-you.png) | [light](html/light/iphone-duo-01-closed-needs-you.html) · [dark](html/dark/iphone-duo-01-closed-needs-you.html) | 464×676 | 05 |
| iPhone Duo closed · Project chat | [light](png/light/iphone-duo-02-closed-project-chat.png) · [dark](png/dark/iphone-duo-02-closed-project-chat.png) | [light](html/light/iphone-duo-02-closed-project-chat.html) · [dark](html/dark/iphone-duo-02-closed-project-chat.html) | 464×676 | 05 |
| iPhone Duo closed · Answer | [light](png/light/iphone-duo-03-closed-answer.png) · [dark](png/dark/iphone-duo-03-closed-answer.png) | [light](html/light/iphone-duo-03-closed-answer.html) · [dark](html/dark/iphone-duo-03-closed-answer.html) | 464×676 | 05 |
| iPhone Duo open · Tasks | [light](png/light/iphone-duo-04-open-tasks.png) · [dark](png/dark/iphone-duo-04-open-tasks.png) | [light](html/light/iphone-duo-04-open-tasks.html) · [dark](html/dark/iphone-duo-04-open-tasks.html) | 952×652 | 05 |
| iPhone Duo open · Human review | [light](png/light/iphone-duo-05-open-human-review.png) · [dark](png/dark/iphone-duo-05-open-human-review.png) | [light](html/light/iphone-duo-05-open-human-review.html) · [dark](html/dark/iphone-duo-05-open-human-review.html) | 952×652 | 05 |

## Not drawn yet
Add Project, Settings › Hooks, list view, usage meter, paused banner, first run, error states, changes sheet, Send Back sheet, recording player, Duo closed Backlog/Instructions. See `docs/spec/08-open-questions.md` and build them in the same visual language (`docs/spec/06-design-system.md`).
