# Security and data

For a vulnerability, use [GitHub’s private vulnerability reporting](https://github.com/jmking/build-mate/security/advisories/new). Do not put credentials, private repository contents or sensitive logs in a public issue. This project is an early preview; use the latest release.

Build Mate runs coding agents, Git and configured shell hooks as your macOS user. Hooks and local previews are trusted commands you choose; the app itself is not an App Sandbox container. Task agents have explicit worktree/Git write permissions, and project chat is read-only. These boundaries do not make untrusted repository code safe to build or execute.

Codex, GitHub CLI and TWG CLI retain their own credentials. Signing/notarization credentials stay in the maintainer’s Keychain. Build Mate does not require you to paste tokens into a chat. Permission expansion and unsupported secret-entry requests are declined.

App data, including chat history, attachments, logs and worktrees, is stored under `~/Library/Application Support/Build Mate/`. Content sent to an agent is processed by the configured Codex service/account. PRs, comments and commits are sent to GitHub when those workflows run. There is no Build Mate cloud backend or analytics service.

Inspect logs and attachments before sharing them: automated redaction is not a guarantee that all sensitive repository content has been removed. Deleting a task removes its app-owned data and worktree, but not its existing GitHub PR or Git branch. Back up work you need before deleting it.
