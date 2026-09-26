# 08 · Open questions and spikes

Record findings inline (date, what was tested, result) and update the affected spec section.

## Spikes before milestone 2
1. **Codex app-server session lifecycle** (codex-cli ≥ 0.151): confirm `thread/start` → `turn/start` → continuation turns; `thread/resume` after the process restarts (context retained); `turn/steer` during an active turn; clean pause with `turn/interrupt`; token and rate-limit notifications; sandbox confined to the worktree with network on.
2. **Agent tools**: can dynamic tools (`DynamicToolSpec`, `item/tool/call`) be registered per thread in the current app-server, or must Build Mate use a per-session MCP server via the `config` override? Pick one and document the exact registration.
3. **Instructions updates mid-thread**: can `developerInstructions` change after `thread/start`? If not, use `thread/inject_items` or restart the thread with history.
4. **Video attachments**: does the selected model accept `localAudio`? If not, transcribe locally (Speech framework) and send text.
5. **TWG CLI for Bitbucket Cloud**: map every operation in 03 §3 to exact `twg` commands (Command Catalog), confirm JSON output, token setup UX (`twg setup bitbucket`), and rate limits. Where a command is missing, use the Bitbucket REST fallback with the same token.
6. **Recording**: choose the default approach: project-provided Playwright command (video on) versus agent-driven browser with capture by Build Mate. Measure reliability on one web project.

## Decisions
- **Decided (2026-09-26):** proof (recording, checks) is never added to PR descriptions; PR bodies contain only the change summary, with no Build Mate branding.

## Decisions to confirm with the owner
- Default "Agents at once" (spec: 4; designs show 10 as sample data).
- Branch naming convention (spec: `<number>-<slug>`, optional prefix).
- Retention for recordings and logs (spec: logs 14 days; recordings kept until the task is deleted).

## Known gaps in the designs
- Not drawn: Add Project, Hooks tab, list view, usage meter, paused banner, first-run, error states, changes sheet, larger recording player, Send Back sheet, Duo closed Backlog/Instructions. Build them from 04 and 06 in the same visual language.
- The Building composer placeholder says "It reads this on its next turn"; use "Message the agent" (agents receive steer messages immediately).
- The designs' "Studio · 4 building" host chip and Remote screen are v2.

## Milestone 1 findings — 2026-09-26

Manually tested against **codex-cli 0.151.0**, Xcode **27.0 (27A266a)**, on this Mac. Reproducible manual probes are in `scripts/spikes/`; these are deliberately excluded from the automated suite. The probes use disposable git repositories/worktrees and print no account/auth payloads.

- **Session lifecycle passed**: initialize → thread/start → two turn/start calls; a running sleep turn accepted turn/steer and answered `STEERED`; turn/interrupt reported `interrupted`; after terminating app-server and starting a fresh process, thread/resume retained marker `SPIKE-ORCHID-739`. Token-usage and rate-limit update notifications arrived; account/rateLimits/read returned populated limits.
- **Choose dynamic tools**: initialize with `capabilities.experimentalApi: true`; pass `dynamicTools: [{name, description, inputSchema}]` to thread/start. Codex issued item/tool/call; the client replied `{contentItems:[{type:"inputText",text:"…"}],success:true}`. The same tool remained available after a process restart and thread/resume, without re-registration. No MCP server, listener, helper or XPC is needed. The checked-in stable schema omits this experimental field; regenerate with `codex app-server generate-json-schema --experimental --out <scratch-dir>` to inspect it.
- **Sandbox passed with explicit turn policy**: workspaceWrite, writableRoots containing only the worktree, networkAccess true, excludeTmpdirEnvVar true, excludeSlashTmp true. An in-worktree write succeeded, a parent write failed with `operation not permitted`, and HTTPS returned 200. Using only thread/start's workspace-write default was insufficient for a temporary workspace: its sibling was writable. Always send the explicit policy on turn/start.
- **Instruction override limitation reproduced**: after a completed turn, restarting and passing a changed developerInstructions to thread/resume returned success but the model still followed the original suffix (`ORIGINAL`, not `UPDATED`). Do not rely on this override in 0.151. Use a fixed lifecycle developer brief directing the agent to the current instructions supplied in each turn's text. Regenerate these from SQLite on every turn; project instructions override global instructions. No history injection or new thread required. Active-turn instruction edits take effect at the next turn.
- **Model resolution**: omitting model selected an unusable local default in the permissions probe. model/list reported the account default; explicitly selecting that ID worked. Resolve the account default instead of hard-coding an ID. A stored explicit user model remains authoritative.
- **TWG unavailable**: `command -v twg` found nothing. No Bitbucket credentials were read or installed. Commands are catalog-confirmed only; exact REST methods/bodies are recorded in 03 §3. Authenticated output envelopes, flags, rate limiting and token transport remain to verify before milestone 5's Bitbucket provider.
- **Recording approach**: choose a project-provided Playwright command, with MP4/H.264 output at `$BUILD_MATE_RECORDING_PATH`. Three runs against a tiny local interactive web fixture succeeded (1.054 s, 0.521 s, 0.349 s; 2,889 bytes each) using installed Chrome and ffmpeg. Initial capture failed because Playwright's ffmpeg cache was absent; supplying the existing ffmpeg through an isolated temporary cache fixed it. This proves the mechanism, not reliability on a production web app. Playwright/ffmpeg belong to the project's hook toolchain, not app dependencies. Agent-driven capture remains a later lifecycle implementation choice.
- **Audio remains unverified**: no model/audio capability claim is made. Video ingestion is outside milestone 2; use a transcript plus localImage keyframes until tested in that milestone.

### TWG setup for the owner

Run interactively in Terminal (the installer opens Atlassian sign-in):

```sh
curl -fsSL --retry 2 https://teamwork-graph.atlassian.com/cli/install -o /tmp/twg-install.sh
bash /tmp/twg-install.sh
twg setup bitbucket
twg doctor
twg bitbucket repo get --help
twg bitbucket pull-requests create --help
```

Follow the Bitbucket token prompt; do not put the token in Build Mate, this repository or chat. If installation prints a PATH adjustment, apply it and open a new terminal. Then test a read against a disposable Bitbucket Cloud repository and validate create/retarget/merge there before enabling that provider.

Sources: [Codex app-server](https://developers.openai.com/codex/app-server), [TWG installation](https://developer.atlassian.com/platform/teamwork-graph/twg-cli/getting-started/installation/), [TWG catalog](https://developer.atlassian.com/platform/teamwork-graph/twg-cli/commands/commands-catalog/), [Bitbucket PR REST](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/), [commit statuses](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-commit-statuses/).

## Milestone 2 implementation assumptions

- The milestone's end-to-end demo drives the real Swift core through its public operations. The hostless test target compiles the same core files, places fake codex/gh/twg on an isolated PATH and uses a real local bare git remote. No internal application mocks or real host calls. The native launch screen is intentionally minimal; the designed workspace begins in milestone 3.
- The main-flow test needs a small lifecycle slice ahead of milestones 4/5: persisted questions/plan approval, independently executed checks/recording validation, human review, GitHub create/recover and merged-state polling. Complete UI, preview, stack rebasing, autonomous PR repair and merge remain in their specified later milestones.
- Core defaults remain four agents, two heavy steps, `<number>-<slug>`, logs retained for 14 days, media until task deletion. Nothing costly needs an owner decision now.
- A waiting question keeps its dynamic call pending while the process is alive. On app restart, resume the durable thread and provide all persisted answers in the next input. An unanswered question prevents dispatch. Turn-limit exhaustion pauses the task for human attention instead of spinning retries.
- Required recording without a configured command fails proof. Recording must be a playable video with positive duration no greater than 180 seconds. Failed proof returns to the agent; after three failures the core pauses it for attention. Rich Needs You presentation follows in milestone 4.

## Targeted Symphony audit — 2026-09-26

Completed before milestone 3; see [audit](09-symphony-audit.md). Fixed stale dispatch after awaited reconciliation, serialized pause handling, human-wait concurrency accounting, continuous-event timeout enforcement, configuration validation and escaped worktree-root symlinks. `afterRun` failure is now diagnostic only; it does not retry successful work. A live question/approval reserves an agent slot until answered or paused. These choices need no owner decision.
