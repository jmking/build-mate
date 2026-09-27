# Codex runtime audit — 27 September 2026

This audit examines Build Mate's context delivery, prompts, lifecycle and verification overhead. It is a source/protocol audit, not a controlled comparison of model outputs. Matching model and reasoning effort does not establish identical quality, response time or token consumption between Build Mate and Codex desktop.

## Confirmed runtime behavior

- Build Mate runs the installed `codex app-server` over JSON-RPC. Task and project conversations retain their Codex thread IDs and resume those threads; Build Mate does not implement a replacement model runner. Model and effort are supplied on `turn/start`, with selections checked against the CLI's model catalog. A saved change applies to the next turn.
- Task agents work in their assigned Git worktrees with scoped write permissions, including the Git metadata necessary to commit. Project chat inspects a separate checkout read-only and creates/refines tasks through app-owned tools. Its no-edit/no-build boundary is intentional product behavior, not a model limitation.
- Native tools, configured integrations and model availability depend on the installed CLI/account and runtime configuration. Launching the CLI does not establish that it has every tool supplied by the desktop host. Adding a tool name to a prompt does not provide that capability.
- Native delegation uses the CLI's subagents. Build Mate enables it for task/project conversations, routes child activity separately and reserves task/project lifecycle tools for the parent. Title generation remains a separate inexpensive, ephemeral request only when a manually created task needs a title.

The local **codex-cli 0.157.1** schema and bounded native subagent probes are recorded in [open questions and spikes](spec/08-open-questions.md#native-codex-subagent-protocol-spike--2026-09-27). Those probes verified protocol behavior, not coding quality or performance parity. They must not be described as read-only metadata calls: some ran fixed-result agent turns and bounded sleep commands. The separate runtime comparison below used read-only metadata requests and selected nonsecret configuration fields, without model inference, credential inspection or user configuration writes.

## Runtime inventory and native preferences

On this Mac, the audit's PATH resolved `codex` to standalone **0.157.1** at `~/.local/bin/codex`. The desktop bundle at `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` reported **0.158.0-alpha.2**; the desktop app reported **26.924.20706**. Build Mate launches `codex` through its inherited PATH, so a Finder launch can resolve differently from this shell. Do not silently substitute the desktop's private bundled binary or claim matching versions without checking the actual executable.

Both binaries returned the same global inventory during this audit:

- Seven picker-visible models with matching supported efforts; Astra, Sol and Luna were available.
- Matching queried feature flags, including enabled shell execution, image viewing, subagents, apps, plugins, browser/computer use and image generation.
- Thirteen discovered skills with no discovery errors, 135 connector tools, four Node REPL tools and three CUA REPL tools. Nine apps reported enabled and callable. The desktop-app control server, `codex_app`, exposed no tools in these standalone probes.

These calls used the audit process's inherited environment and no loaded task thread. They do not establish that desktop bridge operations work from a Finder-launched Build Mate, that per-thread permissions are identical, or that every tool completes successfully. The [MCP documentation](https://learn.chatgpt.com/docs/extend/mcp) confirms shared host configuration; desktop-specific UI/OS integration is still separate. No blanket feature override is warranted by these results.

The model catalogue is not the resolved user preference. The [app-server documentation](https://learn.chatgpt.com/docs/app-server#models) describes `isDefault` as the recommended model and `defaultReasoningEffort` as a suggested effort. A metadata-only app-server process launched with the temporary CLI override `-c model="gpt-6-luna"` returned Luna from `config/read`, while `model/list` still marked Astra as default. The same resolved configuration reported high effort while Astra's catalogue suggested medium. No configuration file or conversation was changed by that check.

Build Mate therefore reads only `model` and `model_reasoning_effort` from one cached, cwd-specific `config/read` per client. Explicit task/project choices win, then the resolved Codex preference, then the catalogue recommendation. The explicit Astra High project-chat default remains. Keep these defaults per client, not in the shared model catalogue, so concurrent projects cannot replace each other's preferences. An unavailable configured model or unsupported effort should produce the existing selection error, not silently select another model.

Build Mate does not send `serviceTier` or change `service_tier`; speed/service-tier behavior remains Codex-owned. The audited configuration reported `priority`. This establishes that Build Mate is not overriding that preference, not that response latency or resumed-thread tier behavior was measured. Similarly, project chat's disabled command networking does not disable hosted web search. Search remains inherited; Codex documents cached search as the local default and treats it separately from shell network permissions. [Web search documentation](https://learn.chatgpt.com/docs/web-search#configure-local-web-search)

## Client capability boundaries

Native tool availability alone is insufficient when a client cannot complete the interaction. Build Mate now sends schema-valid declines for command/file approvals, broader permission requests and MCP elicitation, with a fixed explanation instead of storing request arguments, private URLs or prompts. It does not automatically grant access or implement a new approval UI. Unknown server requests remain unsupported, and child requests retain their stricter boundary. Native secret-entry questions must not persist secrets in normal chat storage; authentication remains with the owning tool. Nonblocking native questions must not turn into a blocking task decision.

Generated images use only the native current-parent/current-turn `imageGeneration.savedPath` field. A successful, regular, nonsymlink, decodable image within the existing 50 MB limit is copied into app-owned attachments and shown through the existing preview UI. Native item/turn identity prevents duplicate attachments. Raw/base64-only results, arbitrary Markdown image paths, missing files and unsupported output forms do not trigger broad file reads; unsupported results receive a short explanation. This is saved-image support, not a claim to render every native media type.

## Findings and corrections

The baseline before this audit duplicated content despite resuming durable threads:

| Confirmed finding | Correction |
| --- | --- |
| Project turns appended the complete saved conversation again; task turns appended every prior answer and user message, including messages already steered into an active turn. | Track successful delivery persistently. Bootstrap once, then deliver new user input/answers and changed brief/settings. Preserve unsent input across restart, interruption and edits. |
| Every turn resubmitted all associated images/video frames. | Deliver attachments with their originating input once; retain owned files and history for later reference. |
| Every project reply included full descriptions of all tasks, including merged work. | Use compact or changed project context and retrieve detail when needed. |
| Continuations repeated static workflow instructions and mandatory planning language. A legacy JSON fallback also matched the modern review schema. | Keep stable guidance concise; distinguish continuing approved work from replanning changed scope. Restrict legacy recovery advice to actual schema/validation failures. |
| Task replies waited until item completion, and quiet commands could trigger the silence watchdog. | Stream task deltas into one message and keep known running commands out of the silence watchdog; retain the overall deadline. |
| Progress-only tool calls could reset the empty-response guard. | Preserve useful autonomous continuation while detecting repeated responses without substantive work. |
| Duplicate configured/submitted checks ran twice, captures ran after failed required checks, and failure replies omitted available diagnostics. | Deduplicate commands while preserving requiredness, defer capture until required checks pass, and return bounded redacted diagnostics with owned log paths. |

These are concrete sources of avoidable input/work, not measured percentage savings. The implementation and process-boundary regression suite establish which corrections have landed; the corrections above are implemented.

## Boundaries to preserve

Keep user history, feedback, attachment ownership, model/effort changes, plan approval when required, independent proof verification and same-thread resumption. A content-delivery optimization must not silently drop user input or treat a failed request as delivered. Proof must still fail when a required check or required evidence is missing. Do not trade these guarantees for a smaller token count.

Any future performance comparison needs the same task, repository revision, model/effort, permissions, tools and acceptance criteria, with separately measured startup latency, time to first response, total completion time and reported usage. Metadata availability alone cannot substantiate a quality or speed claim.


## Regression validation

The macOS app/test build succeeds and all 14 existing process-boundary/state-machine tests pass in 123.0 seconds. Expanded flows verify same-thread delivery across restarts and failed sends, live steering, changed guidance, configured versus catalogue model/effort defaults, task streaming, quiet commands, note-only loop detection, native request responses, generated image ownership/deduplication and proof execution/feedback. No real inference or hosted SCM calls are used in these tests. The running app was not restarted. This establishes integration regressions, not a model-output quality or token/latency benchmark.
