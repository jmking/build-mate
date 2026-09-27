# Autonomous workflow implementation

Scope authorized on 27 September 2026: implement all recommendations from the workflow audit. The requested outcome is a project conversation that turns evolving requirements into appropriately scoped, verified changes and follows hosted review through merge.

Implementation checklist:

- [ ] Correctness: fresh remote bases, publish the verified commit, revision-bound proof, repeated review notifications, recoverable host actions.
- [x] Intake: readiness, search existing work, revise queued/running/review/PR work, linked follow-ups after merge, relevant attachments only.
- [x] Delivery sizing: explicit split/combine operations, preserved requirements and dependencies, coherent review units.
- [x] Model choice: validated recommendations saved before dispatch, rationale, sticky explicit user choices, Astra High project default.
- [ ] Self-QA: execute evidence, return actual artifacts to the agent, inspect/fix before human review, invalidate on changed code or requirements.
- [ ] Hosted workflow: GitHub status, reviews and CI (authenticated Bitbucket deferred by the user); bounded evidence-based reruns, repairs/replies, human decisions and merge rules.
- [ ] Scheduling: release capacity during human waits, accept follow-ups, fair interactive/repair/dependency scheduling, overlap and compute pressure.
- [ ] Native UI: useful status and decisions without extra routine controls or clutter; accessibility and tooltips.
- [ ] Validation: process-boundary regressions and current specifications; document any authenticated host verification that cannot run locally.

Repository scope notes: this authorization brings split/combine delivery and the complete hosted workflow into current scope. It does not authorize posting comments or opening/merging test PRs in the user's real repositories. Live destructive integration verification needs a designated disposable repository; automated tests use isolated fake tools and local Git remotes.
