# Build Mate

Turn ideas into reviewed pull requests, with a native Mac app built around Codex.

Discuss work in project chat, let the agent clarify and organise it into tasks, then follow each task through building, checks, your review and GitHub review. Each task works in its own Git worktree, leaving your checkout alone.

- Group multiple repositories into a project.
- Run tasks in parallel, with dependencies and model/effort choices.
- Share screenshots and files in chat; inspect checks, screenshots and recordings before approving work.
- Address PR feedback and failed CI, then merge when the repository’s requirements are met.

## Install

**Apple Silicon · macOS 26 or later · early preview**

Download the signed, notarized DMG from [Releases](https://github.com/jmking/build-mate/releases), open it, and drag **Build Mate** into **Applications**. Intel Macs are not supported by the release build.

You also need:

- [Codex CLI](https://github.com/openai/codex), installed and signed in with `codex login`.
- Git, and [GitHub CLI](https://cli.github.com/) signed in with `gh auth login` for GitHub projects.
- The tools your repositories need to build and test.

Open Build Mate, add a repository, and describe what you want in project chat. Review the proposed tasks before queuing them. Project Settings lets you add repositories, rename the project and configure checks or previews.

## Current limits

GitHub is the supported PR host. Bitbucket execution and Claude are not available yet. Local repositories can build and reach human review, but publishing and merging local-only work are not implemented. PR monitoring runs while the app is open. Tool availability depends on your installed Codex CLI; desktop-only Codex features are not guaranteed.

This is an early preview. Start with a repository you can comfortably experiment with and review the results. There is no in-app updater yet; install newer builds from Releases.

## Develop

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). GRDB is the only package dependency.

```sh
brew install xcodegen
./scripts/check.sh
open '.build/Build/Products/Debug/Build Mate Dev.app'
```

Read [AGENTS.md](AGENTS.md) for development rules and a code map, [architecture](docs/architecture.md) for the workflow, and [releasing](docs/releasing.md) for signing and packaging. Human and agent contributions follow the same process: a focused change, relevant validation and a clear pull request.

App data lives in `~/Library/Application Support/Build Mate/`. Debug builds are a separate app, **Build Mate Dev** (`com.buildmate.app.dev`, orange icon), with their own data in `Build Mate Dev/`, so they can run beside an installed release. Codex and GitHub CLI own their credentials. [Security and data handling](SECURITY.md) describes the boundaries.

[MIT licensed](LICENSE). Built by Justin King. Build Mate is an independent project, not an OpenAI product.
