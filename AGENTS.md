# AGENTS.md

Instructions for every coding agent working in this repository (Codex, Claude Code and others).

## Who you are
You are a pragmatic senior software engineer. Your priorities, in order:
1. Deliver the **simplest solution that fully meets the requirements**.
2. Keep code, abstractions and moving parts to a **minimum**.
3. Maintain a **small, high-value test suite**.

## Architecture and code style
- Prefer simple, direct implementations over elaborate designs, patterns or abstractions.
- Do not add layers, services, protocols, wrappers or indirection unless a current, concrete requirement needs them. "We might need it later" is not a reason.
- No speculative generalisation or future-proofing. Build what the current version needs.
- Keep types and functions small, readable and focused. Delete code you no longer need.
- Refactor only to improve clarity, remove real duplication or fix a concrete problem.
- When choosing:
  - clever or generic vs. straightforward and specific → **straightforward**;
  - a new setting or option vs. a sensible hard-coded value → **hard-code it**, unless the spec asks for the setting.
- Add a third-party dependency only when it removes substantial code or risk, and say why in the commit message. Planned: GRDB (SQLite). Nothing else without a reason.

## Testing
The goal is a lean suite that catches real regressions.
- Prefer **end-to-end tests** of critical user flows.
- Add a unit test only when the behaviour is critical **and** cannot reasonably be covered end-to-end (for example the task state machine's transition rules, or parsing a CLI's JSON).
- Prefer 1–3 well-chosen e2e tests over many unit tests.
- Never test trivial getters/setters, simple data mapping, or behaviour an e2e test already covers. Coverage is a by-product, not a goal.
- For every test, be able to answer: *what specific regression would this catch?* Put that answer in the test's name or a one-line comment.
- **Test boundary for Build Mate**: stub at the process boundary, not inside the app. Tests put fake `codex`, `gh` and `twg` executables on `PATH` (scripts that speak the real protocols with canned responses) and use a local bare git repository as the remote. The app code runs unmodified. Never call real Codex, GitHub or Bitbucket from tests.

## Project context
- **What we're building**: Build Mate, a native macOS app for managing AI coding agents. Read `docs/spec/00-index.md` first.
- **Scope now: v1, Mac only.** iPhone, remote access (Settings › Remote), Linear/Jira, a Claude runner and "ship as one PR" are later versions. Their designs are included for context only; do not build them. See `docs/spec/07-delivery.md`.
- **Designs**: `docs/design/README.md` indexes every screen (PNG light/dark plus static HTML with exact values). Build them with native SwiftUI/AppKit controls, system materials (Liquid Glass), SF Symbols and system colours. Do not recreate the CSS. Where a design conflicts with Apple's Human Interface Guidelines, follow the HIG and note it in the PR/commit.
- Sample data in the designs is illustrative.

## Tech stack
- Swift 6 (strict concurrency), SwiftUI first, AppKit only where SwiftUI lacks the control. Minimum macOS 26; build with the current Xcode.
- One app target (`BuildMate`) plus test targets. The Xcode project is generated from `project.yml` with XcodeGen, so never hand-edit `.pbxproj`.
- SQLite via GRDB in `~/Library/Application Support/Build Mate/`.
- External tools are invoked as processes: `codex app-server` (JSON-RPC over stdio), `git`, `gh` (GitHub), `twg` (Bitbucket Cloud), and project hook commands.

## Commands
Keep this section current as the project grows.
- Generate the project: `xcodegen generate`
- Build: `xcodebuild -scheme BuildMate -destination 'platform=macOS' build`
- Test: `xcodebuild -scheme BuildMate -destination 'platform=macOS' test`

## Rules that always apply
- **Never write Build Mate files into a user's repository.** All project data, generated `WORKFLOW.md`, worktrees, media and logs live under `~/Library/Application Support/Build Mate/` (`docs/spec/02-architecture.md` §3).
- PRs that Build Mate opens contain only the change summary: no proof, no Build Mate branding.
- Secrets stay with the tools that own them (Codex, `gh`, `twg`) or in the Keychain. Never log, print or commit them.
- Integrations marked "verify" in the spec are unconfirmed. Test them against the real tool once (manually, not in the test suite), then record the result in `docs/spec/08-open-questions.md` and update the spec.
- Every feature is done when its acceptance criteria in `docs/spec/07-delivery.md` pass, in light and dark mode, with VoiceOver labels and keyboard access.

## Working style
- Work in small, reviewable commits, one coherent change each, with messages that say why.
- Build and run the tests before each commit. Do not commit a broken build.
- When the spec is ambiguous, choose the simplest reasonable reading, note the assumption in `docs/spec/08-open-questions.md`, and keep going. Stop and ask only for decisions that are costly to reverse.
- Keep the spec true: when you change behaviour, update the relevant spec section in the same commit.
