# 08 · Open questions and spikes

Record findings inline (date, what was tested, result) and update the affected spec section.

## Spikes before milestone 2
1. **Codex app-server session lifecycle** (codex-cli ≥ 0.151): confirm `thread/start` → `turn/start` → continuation turns; `thread/resume` after the process restarts (context retained); `turn/steer` during an active turn; clean pause with `turn/interrupt`; token and rate-limit notifications; sandbox confined to the worktree with network on.
2. **Agent tools**: can dynamic tools (`DynamicToolSpec`, `item/tool/call`) be registered per thread in the current app-server, or must Build Mate use a per-session MCP server via the `config` override? Pick one and document the exact registration.
3. **Instructions updates mid-thread**: can `developerInstructions` change after `thread/start`? If not, use `thread/inject_items` or restart the thread with history.
4. **Video attachments**: does the selected model accept `localAudio`? If not, transcribe locally (Speech framework) and send text.
5. **TWG CLI for Bitbucket Cloud**: map every operation in 03 §3 to exact `twg` commands (Command Catalog), confirm JSON output, token setup UX (`twg setup bitbucket`), and rate limits. Where a command is missing, use the Bitbucket REST fallback with the same token.
6. **Recording**: choose the default approach: project-provided Playwright command (video on) versus agent-driven browser with helper-side capture. Measure reliability on one web project.

## Decisions to confirm with the owner
- Default "Agents at once" (spec: 4; designs show 10 as sample data).
- Whether proof (recording and checks) goes into PR descriptions by default for team visibility, given the "invisible to the team" principle (spec default: include checks summary, omit the Build Mate footer).
- Branch naming convention (spec: `<number>-<slug>`, optional prefix).
- Retention for recordings and logs (spec: logs 14 days; recordings kept until the task is deleted).

## Known gaps in the designs
- Not drawn: Add Project, Hooks tab, list view, usage meter, paused banner, first-run, error states, changes sheet, larger recording player, Send Back sheet, Duo closed Backlog/Instructions. Build them from 04 and 06 in the same visual language.
- The Building composer placeholder says "It reads this on its next turn"; use "Message the agent" (agents receive steer messages immediately).
- The designs' "Studio · 4 building" host chip and Remote screen are v2.
