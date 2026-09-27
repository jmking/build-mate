# Working on Build Mate

You are a pragmatic senior engineer. Deliver the simplest complete solution, keep the code small, and maintain a lean test suite. These instructions apply to every coding agent; human contributors should use the same workflow.

## Start here

Read `README.md` and `docs/architecture.md`, then inspect the relevant code and tests. The running product and current implementation are the source of truth; do not invent scope from old plans. Check `git status` first and preserve other work.

Build Mate is a native macOS app that turns project conversations into scoped tasks, builds them with Codex in isolated Git worktrees, verifies the results and follows GitHub review through merge. Projects can link multiple repositories; each task and PR targets exactly one repository.

Current scope: macOS 26+, Apple Silicon releases, Codex and GitHub. Bitbucket execution, Claude, mobile/remote access, issue-tracker integrations and combined multi-task PRs are not implemented. Do not add these without a specific request.

## Build and test

Use Xcode 27, Swift 6 strict concurrency and XcodeGen (`brew install xcodegen`). GRDB is the sole package dependency, pinned in `project.yml`.

```sh
./scripts/check.sh                 # Generate, build app/tests, run the isolated suite
open '.build/Build/Products/Debug/Build Mate.app'
```

For a build without tests:

```sh
xcodegen generate
xcodebuild -scheme BuildMate -destination 'platform=macOS' -derivedDataPath .build build
```

Never hand-edit `BuildMate.xcodeproj`; it is generated and ignored. Optional UI tests use `xcodebuild -scheme BuildMateUI -destination 'platform=macOS' test` and need an unlocked Mac with a working Xcode automation host. No signing account or real service credentials are needed to develop or run the automated suite.

For manual testing, launch the executable with `BUILD_MATE_DATA_ROOT` set to a temporary directory so it cannot alter a real workspace. `BUILD_MATE_APPEARANCE=light` or `dark` selects the appearance. External tools are still real unless you supply fixtures on `PATH`.

## Code map

| Area | Start here |
| --- | --- |
| App lifecycle and commands | `BuildMate/BuildMateApp.swift` |
| UI state, navigation, snapshots | `BuildMate/UI/AppModel.swift`, `MainWindow.swift` |
| Task dispatch, recovery, transitions | `BuildMate/Core/Orchestrator.swift`, `Models.swift` |
| Persistence and migrations | `Store.swift`, `ProjectRepositories.swift` |
| Project conversations and task intake | `ProjectChat.swift`, `ProjectAgentTools.swift`, `TaskIntake.swift` |
| Codex protocol and runner boundary | `CodexClient.swift`, `CodexRunner.swift`, `AgentRunner.swift`, `AgentEvents.swift` |
| Worktrees, verification and previews | `Workspace.swift`, `ProofRunner.swift`, `SelfQA.swift`, `Previews.swift` |
| PR publishing, reviews and CI | `GitHub.swift`, `HostedReview.swift` |
| Isolated process-boundary tests | `BuildMateTests/` and `BuildMateTests/Fixtures/` |

Core filenames in this table live under `BuildMate/Core/` unless shown otherwise.

## Implementation rules

- Prefer direct code over generic frameworks. Add an abstraction only for a concrete current need. No speculative provider capabilities, settings or dependencies.
- SwiftUI first; AppKit where needed. Use native macOS controls, SF Symbols, system colours and materials. Follow Apple’s HIG. Keep spacing, alignment, keyboard navigation, accessibility labels, tooltips and Reduce Motion support deliberate. Check visual changes in light and dark mode; report any checks you could not perform.
- Keep task identity, project display names and repository identity separate. Resolve task Git/host operations through `store.project(for:)`, not a project’s legacy repository fields.
- Never put Build Mate metadata in a user’s checkout. App-owned worktrees, generated workflow files, logs and media belong in Application Support. Normal Git worktree metadata necessarily lives in the repository’s Git directory.
- Keep credentials with Codex, `gh`, or the Keychain. Never print, persist or commit secrets. Don’t weaken sandboxing or approval boundaries to fix an integration.
- Preserve native thread IDs, unsent input, attachment ownership and revision-bound proof. Do not resend entire conversations or repeat completed checks without a reason.
- Only the parent agent may mutate Build Mate task/project lifecycle. Child activity must stay scoped to its parent.
- PR descriptions contain a concise Markdown change summary, not proof reports, JSON or Build Mate branding. Never bypass repository merge protections.
- Keep migrations additive and preserve existing data. Cleanups must respect app-owned path checks and unfinished work.

## Validation and contributions

Stub **only at the process boundary**. Tests put fake `codex`, `gh` and `twg` executables on `PATH` and use local bare Git remotes. Never call real models, GitHub or Bitbucket from automated tests, and never use the user’s app data. Manual integration probes under `scripts/spikes/` are separate, opt-in work: they can consume credits and use external tools.

Prefer a few end-to-end tests for critical flows. Add a unit test only for critical behavior that cannot reasonably be covered end-to-end, such as transition rules or protocol parsing. Do not test trivial mapping/getters or duplicate existing coverage. Each test must name the regression it catches. No new test is needed for a simple reversible label/layout edit.

Build and run the suite before committing. Make small, coherent commits explaining why. Update the relevant current documentation when behavior changes; do not add another milestone log or duplicate specification. State what changed, how it was checked and remaining limitations in the PR. For ambiguous, reversible details, choose the simplest reasonable behavior and continue; ask about costly-to-reverse decisions.

For releases, follow `docs/releasing.md`. Never publish an unsigned or unnotarized build, export signing secrets into the repository, or publish/tag a different commit from the one that produced the artifact.
