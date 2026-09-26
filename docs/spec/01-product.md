# 01 · Product

## Problem
Coding agents can now do most of the implementation for well-described work, but using them means supervising sessions: starting them, watching them, answering them, checking their output, opening PRs, fixing CI, chasing reviews. With several agents running at once, the human becomes the bottleneck and the context-switching cost is high. Tools like Cursor's Agents Window make running parallel agents easy, but they stay session-centric and editor-centric.

## What Build Mate is
A Mac app where you **manage work instead of supervising agents**:
- You talk to a **project chat**. It reads the codebase and proposes a set of **tasks** (with dependencies and how they ship).
- Tasks wait in a **Backlog** until you move them to **Todo** (or you tell the chat to start now).
- Each task gets its own **agent** in its own **git worktree**. The agent asks questions when unclear, builds, and produces **proof of work** (relevant checks and visual evidence when appropriate).
- You do a **human review** with the evidence and a one-click **Run locally**, then the agent opens a **pull request** and looks after it until it is **merged**.
- Everything that needs you lands in one place: **Needs You**, on the Mac, in the menu bar and on your iPhone.

## Principles
1. **Merged is the finish line.** Every task shows where it is on its road to merge, not how many turns an agent has taken.
2. **Needs You is home.** The app's job is to minimise and batch the moments a human is needed.
3. **Ask, don't guess.** Agents ask clarifying questions before building and at decision points, and never silently expand scope.
4. **Prove it.** A task cannot reach human review without proof (passing checks plus any task-required recording).
5. **Brakes are always in reach.** Pause a task, a project or everything, from anywhere, instantly.
6. **Not an editor, one click from one.** Code opens in your editor (Cursor, VS Code, Xcode). Build Mate never becomes an IDE.
7. **Invisible to the team.** Nothing is written into the repository. The team only sees branches and pull requests.
8. **Native and calm.** Follows Apple's HIG, Liquid Glass used with restraint (Codex-app level), full light and dark mode.

## Users
- **Primary (v1):** a single developer or tech lead on a Mac, using their ChatGPT subscription for Codex, working in one or more repos on GitHub and/or Bitbucket Cloud. The rest of their team does not use Build Mate.
- **Later:** the same person away from their desk (iPhone, v2); teams sharing workflows (v3, export to repo).

## Core concepts and glossary
| Term | Meaning |
|---|---|
| **Project** | One local Git repository (created here or an existing clone) with its settings, instructions, chat and tasks. Local-only, GitHub or Bitbucket Cloud. |
| **Project chat** | A long-running conversation with the **project agent**, which can read the repo (not write) and create tasks. One per project. |
| **Task** | A unit of work with a title, description, attachments, dependencies and a lifecycle state. Numbered per project (`#427`). |
| **Task agent** | The Codex session that works on one task inside that task's worktree. |
| **Worktree** | A `git worktree` for the task's branch, stored in Build Mate's storage, never inside the repo. |
| **Backlog** | Tasks you are not ready to start. Agents never pick these up. |
| **Todo** | Tasks ready for an agent. Picked up in order, respecting dependencies and limits. |
| **Needs Clarification** | The agent has blocking questions for you. |
| **Building** | The agent is implementing. |
| **Human review** | Proof is complete; waiting for you to review before a PR opens. |
| **In PR** | A PR is open. The agent watches it: fixes failing builds, addresses review comments, asks you only for decisions. |
| **Merged** | Pull request merged. |
| **Proof of work** | Evidence produced for review: check results, a change summary, and a recording when appropriate to the task or explicitly requested. |
| **Road to merge** | The five checkpoints every task passes: Clarified → Built → Proof of work → Human review → Merged. |
| **Approval checkpoint** | A point where the agent must wait for you: before building (plan approval), before opening a PR (human review), before merging. Configurable. |
| **Needs You** | The cross-project inbox of everything waiting on you: questions, approvals, PR decisions, reviews. |
| **Instructions** | Rules every agent follows. Per project, plus global ones, plus the repo's own `AGENTS.md` if it has one. |

## Non-goals (v1)
- Being a code editor or diff viewer beyond summaries (open the editor or the PR instead).
- Multi-user accounts, sharing or cloud sync.
- Running agents in the cloud. Agents run on the user's Mac.
- Replacing the team's tracker. The built-in task list is personal; Linear/Jira connectors are v3.
- Anything written into the repository by default.
