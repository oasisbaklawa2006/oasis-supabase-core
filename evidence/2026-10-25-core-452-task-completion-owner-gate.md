# Core #452: task-owner completion and task-scoped idempotency

Mission Control: Central #638 (ASM-06 WhatsApp). Related: Core #451 (released), Central #640 (released), Central #639 (recovery checkpoint
`d8b3a488506f1c950adf6a03a58cb03d4715ef6e`, untouched). Migration: `20261025140000_whatsapp_case_task_completion_owner_gate_v1.sql`.

`PR MERGED != STAGE CLEARED`. Nothing in this change is merged, released or applied to production by the author.

## Finding (reproduced, not assumed)
Replay of Core `main` (`2a07222`) on a disposable database, stock `whatsapp_complete_case_task(uuid,jsonb,text)`:

| # | Reproduction | Result before the repair |
| --- | --- | --- |
| D1 | Support executive S2 completes a task owned by S1 | `COMPLETED`, `completed_by = S2` |
| D2 | S2 completes an unassigned task | `COMPLETED` |
| D3 | Same key used for two tasks of one case | second task returned `idempotent_replay: true` but stayed `OPEN` (false success) |
| D4 | Fresh key on an already COMPLETED task | another `DEPARTMENT_TASK_COMPLETED` event inserted |

## Callers inspected
* Central queue `WhatsAppWorkQueue.tsx` offers Complete only when `ownerUserId === meUserId`: compatible.
* Central conversation console `OperatorInboxCaseLifecycleActions.tsx` calls the same RPC for any open task, including unassigned ones.
  After this change an unassigned task is refused with `CASE_TASK_NOT_CLAIMED` until it is claimed in the work queue. This is the
  intended contract. No Core, edge function, SQL function or script caller exists outside tests.
* `whatsapp_claim_case_task`, `whatsapp_assign_case_task`, `whatsapp_release_case_task`, `has_whatsapp_permission`,
  `whatsapp_is_ownership_supervisor` are unchanged.

## Repair (one new forward-only migration; signature, grants and return shape unchanged)
* Only the current owner may complete. `wa.intake.triage` is still required. Unassigned: `42501 CASE_TASK_NOT_CLAIMED`.
  Other-owned: `42501 CASE_TASK_NOT_OWNER`. Nothing is written on refusal.
* No implicit supervisor path. A supervisor who must finish a colleague's task uses the existing audited route: assign it to
  themselves with a recorded reason (override flagged), then complete as owner. No `wa.intake.assign`, AAL2 or allowlist change.
* Event key is `task-complete-v2:<task_id>:<key>`. The distinct prefix means it can never equal a legacy `task-complete:<caller key>` value
  (a legacy caller key shaped `<task_id>:<key>` would otherwise collide with it and, through the per-case unique key, block the event).
  Replay requires the same task AND the same caller: the event's `resulting_state.task_id` must be this task, whether it carries the new key
  or a legacy `task-complete:<key>`. A legacy event for another task is never reinterpreted. A different caller reusing a key gets no replay.
* Completing an already COMPLETED task with a new key raises `CASE_TASK_ALREADY_COMPLETED` and writes nothing (cancelled keeps its
  original message). Exact replay still returns the original result.
* Completion event `resulting_state` now also records `assigned_user_id`.

## Tests
* pgTAP `supabase/tests/20261025140000_whatsapp_case_task_completion_owner_gate_v1.sql`, 44 assertions: owner completes; non-owner and
  unassigned denied with no row or event change; disabled role, inactive account and deny rule denied; same key on two tasks of one case;
  exact replay; legacy-key replay and non-reinterpretation; a legacy key colliding with a task-scoped key (CodeRabbit finding); completed repeat with no new event; cancelled denied; released then complete
  denied; supervisor has no implicit bypass but can assign-with-reason then complete (override flagged); AAL2 session unchanged;
  step-up flags, assign grants and allowlist untouched; append-only trigger intact; signature and grants unchanged.
* Negative control: the same file against the previous function body fails many assertions (16 in the first run, before the collision case was added); with the new body all 44 pass.
* Core #451 regression files (135000, 136000, 137000, 138000) still pass: 28, 23, 24 and 11 assertions.
* Two-session concurrency (real overlapping transactions, row locks held 3 s):

| Scenario | Session 1 | Session 2 | Outcome |
| --- | --- | --- | --- |
| A | S1 claims unowned task | S2 completes it concurrently | S2 blocked, then `CASE_TASK_NOT_OWNER`; 1 claim event, 0 completion events |
| B | owner completes, key K | owner completes, same key K | second returns `idempotent_replay: true`; 1 completion event |
| C | owner completes, key K1 | owner completes, key K2 | second `CASE_TASK_ALREADY_COMPLETED`; 1 completion event |
| D | owner completes | supervisor takes over | take-over `CASE_TASK_NOT_ASSIGNABLE`; 1 completion event, 0 ownership events |
| E | supervisor takes over (reason) | previous owner completes | owner `CASE_TASK_NOT_OWNER`; 1 override assign event, 0 completion events |

## Production state and rollback
* Read-only census in the issue: 134 OPEN department tasks, all unassigned, zero ownership or completion events. The migration changes a
  function body only; it writes no data and touches no historical row or event.
* Existing completed tasks and legacy-format events stay valid. Rollback is forward-only and must NOT restore the previous body from
  `20260817193859_whatsapp_b2b_case_decision_lifecycle.sql`, which reintroduces the defects above. To change behaviour, ship a new migration
  that keeps the owner gate and task-scoped idempotency. To stop completions entirely in an emergency, a new migration may revoke execute on
  the function from `authenticated` (claim, assign and release are unaffected) until a corrected version is released through the protected
  workflow. Never roll the database back destructively.
* Pre-migration state to record before release: the function body hash and `pg_proc.prosrc` of the current production
  `whatsapp_complete_case_task`, and the count of `DEPARTMENT_TASK_COMPLETED` events.

## Central compatibility (no Central change made here)
* `ownershipErrorMessage` maps `42501` to "You do not have permission for this action", which is acceptable for NOT_OWNER and NOT_CLAIMED.
  `CASE_TASK_ALREADY_COMPLETED` falls to the generic "could not be completed, nothing was changed" message. The queue refreshes after errors.
* Follow-up for Mission Control (not done here, to avoid another UI rebuild): a clearer message for these two codes, and a hint in the
  conversation console that a task must be claimed first. Operationally, staff must claim tasks in the work queue before completing.

## Required owner approvals
1. Review and human approval of the Core PR under Core Main Protection; squash merge by the owner.
2. Approval of the protected production migration release for exactly this migration (the push-triggered run is preflight only).
3. Decision on the follow-up Central message tweak (optional).

## UAT checklist (authenticated, production or preview after release)
Preconditions: one support executive (SE) and one admin (ADM); a handful of unassigned test-safe tasks; no customer messages sent.

SE:
1. Open the work queue; Needs Action lists unassigned tasks. Claim one: it moves to My Tasks, owner shows "You".
2. Complete it with an outcome: it moves to Completed; one completion event exists for that task.
3. Retry completion of the same task from a second browser tab: no second completion event; the second tab shows an error or refresh.
4. Try to claim a task already claimed by a colleague: "A colleague claimed this task first". Confirm no Assign, Reassign or take-over buttons appear.
5. In the conversation console, try Complete task on an unassigned task: refused, nothing changes. Claim it in the queue, then complete.

ADM:
6. Assign an unowned task to SE; reassign it with a reason (a blank reason is refused); the audit event is flagged override.
7. Try Complete on SE's task directly: refused. Assign it to yourself with a reason, then complete: completed with your attribution.
8. Confirm All Conversations remains reachable and the AAL2 prompts for high-risk actions (close) are unchanged.

Both:
9. Two people act on the same task at the same moment (one claim, one complete): exactly one succeeds.
10. Verify after UAT: `select event_type, count(*) from whatsapp_case_events where event_type like 'DEPARTMENT_TASK_%' group by 1` matches the actions taken; no row shows a completer who was not the owner.

## Limits
* Department scoping is not possible (`users.department` is blank for 19 of 21 operators); any operator can still claim any department's unowned task.
* No signed-in browser session was available to the author; UAT above is the authenticated check.
* Concurrency proofs run on a single local database, not on production.
