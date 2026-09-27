# Autonomous workflow implementation

Scope authorized on 27 September 2026: implement all recommendations from the workflow audit. The requested outcome is a project conversation that turns evolving requirements into appropriately scoped, verified changes and follows hosted review through merge.

Implementation checklist:

- [x] Correctness: fresh remote bases, publish the verified commit, revision-bound proof, repeated review notifications, recoverable host actions.
- [x] Intake: readiness, search existing work, revise queued/running/review/PR work, linked follow-ups after merge, relevant attachments only.
- [x] Delivery sizing: explicit split/combine operations, preserved requirements and dependencies, coherent review units.
- [x] Model choice: validated recommendations saved before dispatch, rationale, sticky explicit user choices, Astra High project default.
- [x] Self-QA: execute evidence, return actual artifacts to the agent, inspect/fix before human review, invalidate on changed code or requirements.
- [x] Hosted workflow: GitHub status, reviews and CI (authenticated Bitbucket deferred by the user); bounded evidence-based reruns, repairs/replies, human decisions and merge rules.
- [x] Scheduling: release capacity during human waits, accept follow-ups, fair interactive/repair/dependency scheduling, overlap and compute pressure.
- [x] Native UI: useful status and decisions without extra routine controls or clutter; accessibility and tooltips.
- [x] Validation: process-boundary regressions and current specifications; document any authenticated host verification that cannot run locally.

Repository scope notes: this authorization brings split/combine delivery and the complete hosted workflow into current scope. It does not authorize posting comments or opening/merging test PRs in the user's real repositories. Live destructive integration verification needs a designated disposable repository; automated tests use isolated fake tools and local Git remotes.

Validation completed on 28 September 2026:

- macOS build-for-testing succeeded; all 19 tests in four suites passed (154 seconds). Fake Codex/GitHub processes and local Git remotes exercise intake, scope scheduling, evidence inspection, feedback repair, bounded CI retries, reply recovery, stacked PR retargeting and merge approval bound to the current commit and requirements.
- Native review controls were rendered and inspected in light and dark appearance; the merge explanation wraps without truncation. This was component inspection, not a full-app VoiceOver or UI automation run.
- Authenticated GitHub read-only checks succeeded for PR state, review threads and supported merge methods. Host mutations were tested only through isolated fixtures.
- Bitbucket authentication and end-to-end provider validation remain deferred at the user's request; the integration remains disabled.
