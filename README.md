# Build Mate

Build Mate is a native macOS app (with an iPhone companion) for managing AI coding agents at the level of **work**, not sessions. You describe what you want in a project chat; Build Mate splits it into tasks, runs each task with its own agent in an isolated git worktree, and carries every task through a visible lifecycle to a merged pull request. You step in only where you are needed: answering questions, approving plans, reviewing proof of work.

It is built on the ideas in OpenAI's [Symphony](https://github.com/openai/symphony) (`SPEC.md`): an orchestrator that polls a task tracker, dispatches agents into per-task workspaces, retries, and reconciles state. Build Mate implements that model natively in Swift, with its own built-in task tracker, and extends it (clarification, proof of work, approvals, project chat, remote control).

## Repository layout

| Path | What it is |
|---|---|
| `AGENTS.md` | Instructions for coding agents working in this repo. Read first. |
| `docs/spec/` | The product and engineering specification. Start at `docs/spec/00-index.md`. |
| `docs/design/` | Every designed screen, light and dark: PNGs, static HTML references, icon assets. See `docs/design/README.md`. |

## Status

Specification and visual design only. No code yet. Version plan: `docs/spec/07-delivery.md`.
