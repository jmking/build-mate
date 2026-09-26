# Symphony core audit · 2026-09-26

Scope: dispatch, concurrency, retries, reconciliation, timeouts and workspace safety. Compared Build Mate with [upstream SPEC.md](https://github.com/openai/symphony/blob/main/SPEC.md), sections 6–10, as retrieved on this date. This is a targeted audit, not a claim of full Symphony conformance.

## Corrections before milestone 3

- Re-read SQLite after awaiting reconciliation so edits made during an interrupt cannot be lost to a stale dispatch snapshot. Shutdown blocks further dispatch.
- Interrupt independent workers concurrently. Re-check task/project/global pause and dependencies before launch and each new turn.
- Reserve concurrency for every live worker, including pending human questions/approvals. Resuming a waiting tool cannot silently exceed the process limit.
- Check the turn deadline on every event-loop iteration, including busy streams. Nonpositive stall timeout disables stall detection; human/proof waits remain excluded.
- Validate positive concurrency, turn and hook limits before dispatch. Invalid project settings or a missing dependency do not prevent unrelated projects from dispatching.
- Anchor workspace containment to the trusted app storage root; resolving an escaped `worktrees` symlink cannot redefine that boundary. Check it again after hooks and before launches/turns/removal.
- Log `afterRun` failures without retrying successful coding work. `beforeRemove` remains fail-closed to preserve work.

The existing three process-boundary e2e flows now also check waiting-worker capacity, continuous-event timeouts, disabled stall detection, and a symlink escaping the storage root. The transition unit test remains unchanged.

## Deliberate Build Mate differences

SQLite is the authoritative tracker/configuration source. `WORKFLOW.md` is an app-owned snapshot, not a repository contract, parser or hot-reload input. No Liquid template engine or generic tracker adapter is needed. UUID project directories and numeric task directories avoid identifier sanitization collisions.

Keep the product's 5-second polling, four-agent default, rank ordering, two-proof limit, and persistent thread/session records. There are no additional per-state limits. A task's total turn budget pauses it for human attention instead of automatically cycling workers indefinitely. Normal continuation stays in the live thread with refreshed project/global guidance. Failed attempts reuse the worktree and use persisted exponential retry deadlines; UTC deadlines intentionally survive app restart.

Questions and plan approval can hold a dynamic call open indefinitely without consuming the stall/turn timeout. These live processes reserve capacity; pausing closes them. Keep canceled worktrees until explicit deletion. User-directed follow-up: clean merged worktrees are removed automatically; dirty worktrees and failing removal hooks are preserved and reported. Retry `afterCreate` until setup succeeds. Abort removal if its hook fails or git reports uncommitted changes.

## Remaining later-milestone work

Full PR watch/repair/merge/restacking, user-facing usage holds, preview limits, richer operational activity and UI controls remain in the delivery plan. Do not present this implementation as a general Symphony runtime.
