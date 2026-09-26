# 06 · Design system

Build with **system** colours, materials, fonts and SF Symbols so light/dark, accessibility settings and accent colour changes work for free. Text, accents, status colours and controls use semantic system tokens. Following the owner’s neutral-surface direction (2026-09-26), large Mac backgrounds use the reference light/dark colours through `AppSurface` instead of wallpaper-tinted system backgrounds. This is the explicit exception to the system-colour rule.

## 1. Colour

### Surfaces and text
| Role | System token (SwiftUI / AppKit) | Light (reference) | Dark (reference) |
|---|---|---|---|
| Window content | `windowBackgroundColor` / `.background` | #FFFFFF | #1E1E1E |
| Raised content (inspector) | `underPageBackgroundColor`-like, or `.background.secondary` | #FBFBFC | #232325 |
| Recessed (board columns, settings body) | `.background.tertiary` | #F5F5F7 | #141416 |
| Card on board | `controlBackgroundColor` / `.background` elevated | #FFFFFF | #2C2C2F |
| iOS grouped background / rows | `systemGroupedBackground` / `secondarySystemGroupedBackground` | #F2F2F7 / #FFFFFF | #000000 / #1C1C1E |
| User chat bubble | `quaternarySystemFill`-level fill | #F2F2F5 | #2C2C2E |
| Label | `labelColor` | #1D1D1F | #F5F5F7 |
| Secondary label | `secondaryLabelColor` | #6E6E73 | #98989D |
| Tertiary / placeholder | `tertiaryLabelColor` | #8E8E93 | #8E8E93 |
| Separator | `separatorColor` | #E5E5EA / #EDEDF0 | #38383A / #333336 |
| Selection (sidebar, tabs) | system sidebar selection | rgba(0,0,0,0.065) | rgba(255,255,255,0.11) |

### Accent and status (dark variants are Apple's)
| Role | System colour | Light | Dark | Used for |
|---|---|---|---|---|
| Accent | `controlAccentColor` (user's choice; default blue) | #007AFF | #0A84FF | Primary buttons, selection, sidebar symbols, progress |
| Needs you | `systemPurple` | #AF52DE | #BF5AF2 | Questions, approvals, decisions |
| Success / proof | `systemGreen` | #34C759 | #30D158 | Proof complete, checks passed, road-to-merge done marks |
| Warning / retry | `systemOrange` | #FF9500 | #FF9F0A | Retrying, failing check |
| Paused / neutral | `systemGray` | #8E8E93 | #8E8E93 | Paused marker |
| Badge (iOS tab) | `systemRed` | #FF3B30 | #FF453A | Tab bar count |
| Bitbucket mark | brand | #0052CC | #2684FF | Bitbucket logo only |

Rules: status colour appears on glyphs, dots and bars; **text stays in label colours** for contrast. Accent-soft fills (selected card/row) are accent at 11 % (light) / 24 % (dark).

## 2. Materials (Liquid Glass, restrained)
Target the Codex-app level: glass is present but quiet.
| Element | Implementation | HTML reference |
|---|---|---|
| Sidebar | Native `NavigationSplitView` sidebar with a neutral opaque backing | rgba(243,243,247,0.86) + blur 50 |
| Toolbar buttons and groups | system toolbar items (glass capsules); group related items | rgba(255,255,255,0.86) + blur 16, 0.5 pt border, soft shadow |
| Menu bar popover, menus, sheets | Native presentation; app-owned sheets/popovers use a neutral `presentationBackground` | same family |
| Floating composer | `.glassEffect()` capsule | same family |
| Play buttons over media | `.glassEffect(.clear)`-style, the one place glass is more transparent | white 40→10 % gradient, blur 5 |
| Scroll edge under floating toolbars | system scroll edge effect | white 92→0 % fade |
Enable **Reduce Transparency**: all glass falls back to solid surfaces automatically when system materials are used.

## 3. Typography (SF Pro via system fonts)
| Use | Mac | iPhone |
|---|---|---|
| Large title | — | 34 bold (`.largeTitle`) |
| Screen title in content | 22–26 semibold | 22–28 bold |
| Toolbar title | 15 semibold | 17 semibold (inline) |
| Body / list rows | 13 regular | 17 regular |
| Chat and editors | 14 regular, 21–22 line height | 17 regular |
| Secondary | 12 | 15 (rows), 13 (captions) |
| Section headers | 11–12 semibold secondary | 13 semibold secondary |
| Numbers | tabular (`.monospacedDigit()`) | same |
| Task numbers, paths, branches | SF Mono 11–13 | SF Mono 13 |
Do not set custom letter spacing. Support Dynamic Type on iPhone.

## 4. Layout, spacing, radii
- Spacing scale: 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40.
- Sidebar rows use native `Label` icon/title columns, including project disclosure labels; let the sidebar set symbol size and hierarchy indentation. Keep project folders in label colour. Repeated Needs You rows reserve 20 pt for status glyphs and 12 pt for chevrons. Board headers use 16 pt glyph slots and a common 20 pt height so the Queue add control cannot shift its header or content down.
- Align mixed-size text/control rows to their first text baseline: form fields/buttons, footer captions/actions, task number/title/status, transcript metadata, and Needs You glyph/title/chevron. Wrapped titles stay leading aligned; task metadata stays on the first line. List separators start at the row's leading edge, not underneath trailing status labels.
- Composer: the text field has a minimum 32 pt height with 7 pt optical vertical insets and a large native circular send control. Its single line is vertically centred with the button; when it grows, the last text line remains aligned with the bottom action. Hint and input share a leading edge. Check empty, typed, wrapped and multiline states.
- **Concentric corners**: inner radius = outer radius − padding. Board column 20 → card 12 (8 padding). Sheet 22 → inner panel 12 (10 padding).
- Radii: windows (system, 16 in references), cards 12, grouped boxes 12 (Mac) / 26 (iOS), sheets 22, capsule controls (height ÷ 2), chips 15, badges 9.
- Mac sidebar 232; inspector 340; chat max line width 720; list pane in Backlog 420.
- Control heights: toolbar controls 32, inline buttons 28–34, iOS buttons 44 minimum.

## 5. SF Symbols
| Meaning | Symbol |
|---|---|
| Needs You | `tray` |
| Project chat | `bubble.left` |
| Backlog | `list.bullet.rectangle` (or `tray.2`) |
| Tasks board | `rectangle.split.3x1` |
| Instructions | `doc.text` |
| Queue | `circle.dashed` |
| Needs Clarification | `questionmark.circle` |
| Building | `play.circle` |
| Human review | `eye` |
| In PR | `arrow.triangle.pull` |
| Merged | `checkmark.circle` |
| Pause / resume | `pause.fill` / `play.fill` |
| Add / new task | `plus` |
| Search | `magnifyingglass` |
| Settings | `gearshape` |
| Hooks | `bolt` |
| Remote | `macbook.and.iphone` |
| Back / forward | `chevron.left` / `chevron.right` |
| Inspector | `sidebar.right` |
| More | `ellipsis` |
| Attach | `paperclip` |
| Send | `arrow.up` (in accent circle) |
| Dictation | `mic` |
| Preview | `globe` |
| Refine with Agent | `sparkles` |
| Drag handle | `line.3.horizontal` |
| Changes | `doc` |
| Question | `questionmark.circle` |
Project identity: use the neutral outline `folder` SF Symbol in the label colour, independent of Git hosting. Add 4 pt leading inset to the project disclosure label so the folder has breathing room beside the native chevron; keep the icon/title spacing native. Hide the decorative icon from accessibility; the project name labels the row.

Sidebar Projects header: inset the 20 pt Add Project button by 10 pt on the trailing edge to align its symbol with the native row count badges.

Brand marks are reserved for repository/service-specific actions and information, never the project icon. GitHub and Bitbucket marks (`docs/design/assets/github.svg`, `bitbucket.svg`) follow each brand's usage guidelines: GitHub mark in the label colour, Bitbucket mark in Bitbucket blue. Editor/Terminal/Finder icons are the real app icons from `NSWorkspace` at runtime.

## 6. Components (reference → native)
| Component | Native build |
|---|---|
| Sidebar rows, badges | `List` sidebar style with `.badge()` |
| Toolbar groups | `ToolbarItemGroup` / `ControlGroup` |
| List/Board switch | segmented `Picker` in toolbar |
| Open in editor | `Menu` with primary action (pull-down button) |
| Road to merge checklist | custom vertical list with connecting line |
| Proposal card | custom view with `Toggle` (checkbox style) rows |
| Question card | custom view; answer chips are `Button`s with `.bordered` capsule style |
| Composer | `TextField(axis: .vertical)` in a glass capsule |
| Settings | `Form` with `.grouped` style; `Stepper`, `Toggle` (checkbox on Mac), `Picker` |
| Menu bar extra | `MenuBarExtra(style: .window)` |
| iOS tab bar | `TabView` (iOS 26 floating tab bar) |
| iOS swipe actions | `.swipeActions` |

## 7. Motion
- Use native sheet/popover/inspector presentation. Sidebar and inspector changes use a short smooth animation (0.25 s); page and board/list changes cross-fade (0.18 s). Card moves between board columns use matched geometry (0.35 s spring, restrained bounce). Only a live, unpaused agent turn pulses its status dot.
- Reduce Motion: no pulsing, no card fly-overs (cross-fade instead).

## 8. Accessibility
- Every icon-only control has a label and tooltip; answer chips announce the question.
- Status never relies on colour alone: text accompanies every coloured dot.
- Contrast ≥ 4.5:1 for text in both appearances.
- Full keyboard navigation on Mac (Tab through regions, arrow keys in lists and board, Space to open).
- VoiceOver rotor headings for sections (Questions, Approvals, …).

## Mac implementation refinements (2026-09-26)

- The composer is a regular Liquid Glass surface in a bottom `safeAreaBar`, allowing the transcript to scroll behind it. Keep the delivery hint inside this surface for legibility. The circular send arrow has an action-specific accessibility label and tooltip. Clear glass is reserved for future media controls.
- Use the native SwiftUI inspector (340 pt ideal, 280–380 pt resizable), retaining native presentation with the neutral raised-content background. Do not wrap the sidebar, toolbar or inspector in another glass layer.
- `AppSurface` supplies window (#FFFFFF / #1E1E1E), raised (#FBFBFC / #232325), recessed (#F5F5F7 / #141416), card (#FFFFFF / #2C2C2F), sheet (#F7F7F9 / #2C2C2F) and sidebar (#F3F3F7 / #232325) backgrounds. These opaque light/dark pairs deliberately prevent desktop wallpaper tint from making large surfaces brown. Retain semantic separators, text, accents and card shadows. Toolbar controls and the composer keep native Liquid Glass; no global macOS appearance preferences are changed.
- Transcript events are compact secondary rows; messages use 14 pt system type with 5 pt line spacing. Following the owner’s chat references, agent bubbles use #EEEEEE / #262626 (light/dark), while user bubbles use #080808 / #595959 with white text and 85% white speaker/time labels. Use opaque fills to avoid wallpaper tint. Agent and user messages share speech bubble geometry with 14 pt padding, 12 pt corners and a maximum content width of 560 pt. Agent bubbles align leading; user bubbles align trailing. Keep speaker/time inside each bubble; events remain compact rows and questions retain their interactive cards. Progress checklist labels stay in label colours; only glyphs carry state colour.
- Reduce Motion disables panel movement and pulsing; board updates use opacity instead of geometry travel. Reduced Transparency is handled by native materials.

References checked: [Apple HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Motion](https://developer.apple.com/design/human-interface-guidelines/motion), [Applying Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views). Apple reserves glass for navigation and functional controls; content cards retain standard surfaces. The reference wallpaper is not an app background, so translucency varies with the actual desktop and system preferences.
