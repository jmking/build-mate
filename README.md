# Build Mate

Build Mate v1 is a native macOS app for managing AI coding work through to merge. Swift 6, SwiftUI, macOS 26+, one app process, SQLite via GRDB. Codex runs through `codex app-server`; git and host integrations use their CLIs.

## Status

Milestones 1–4 are implemented, with project text chat brought forward from milestone 6. The native app includes project creation, Needs You, Backlog, board/list views, task conversations, proof review, local previews and editor actions. Project chat can inspect code read-only, propose dependent tasks, route them to Backlog or Queue, answer questions and refine Backlog descriptions. Both chats accept screenshots (window or area), dropped files and file-picker attachments. Attached references follow created tasks and are cleaned up after their linked tasks merge. Video frame extraction and instruction editing remain later work. See the delivery notes for validation limits.

The core supports durable projects/tasks/sessions, guarded state transitions, rank/dependency dispatch, external worktrees, hooks with timeouts, Codex dynamic tools, clarification and plan approval, proof gates, human review, GitHub PR creation and merge detection, retries and reconciliation. The test suite exercises the complete initial lifecycle with fake CLI processes and a real local bare git remote. It never calls real Codex, GitHub or Bitbucket.

Real Codex lifecycle/dynamic tools/sandbox probes passed on 0.151.0. TWG is absent on the development Mac: its authenticated Bitbucket integration remains pending. Full PR watch/repair/merge and restacking are milestone 5. See [findings and setup](docs/spec/08-open-questions.md).

## Build, test and run

Requires the installed Xcode with a macOS 26+ SDK and XcodeGen (`brew install xcodegen`). GRDB 7.11.1 is the sole package dependency. Xcode resolves it on the first build. Do not edit the generated Xcode project.

```sh
xcodegen generate
xcodebuild -scheme BuildMate -destination 'platform=macOS' build
xcodebuild -scheme BuildMate -destination 'platform=macOS' test
```

For a predictable app path:

```sh
xcodebuild -scheme BuildMate -destination 'platform=macOS' -derivedDataPath .build build
open '.build/Build/Products/Debug/Build Mate.app'
```

The app uses `~/Library/Application Support/Build Mate/`. Tests supply separate temporary storage and an isolated environment. The hostless test target compiles the unmodified core sources, avoiding any test launch against real app data. No signing team or credentials are needed for local tests.

## Milestone demos

1. Manual scripts in `scripts/spikes/` exercised real Codex thread/turn continuation, steer, interrupt, resume after restart, usage events, persistent dynamic tools and explicit sandbox boundaries. Three local browser recordings produced valid MP4s. These scripts are manual probes, never part of `xcodebuild test`.
2. `lifecycleKeepsCloneCleanGatesProofAndFinishesOnlyAfterMerge` demonstrates Queue → question → answer → plan approval → build → failed proof → repaired proof → human review → Open Pull Request → Merged. It reopens the database at review, checks the original clone is untouched, and deletes app-owned worktrees/data. Two further e2e flows exercise scheduling/restart and failed/timed-out hooks. One unit test covers transition guards.

## Repository layout

| Path | Contents |
|---|---|
| `AGENTS.md` | Engineering and test rules |
| `project.yml` | XcodeGen source of truth |
| `BuildMate/` | Native app entry point and core |
| `BuildMateTests/` | Process-boundary e2e harness, executable fixtures, transition test |
| `scripts/spikes/` | Manual integration probes; require real external tools |
| `docs/spec/` | Product/engineering spec; start at `00-index.md` |
| `docs/design/` | Light/dark PNGs, HTML references and assets |
