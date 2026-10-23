# WA-RELEASE-04: release order, historical job disposition and rollback

Status: PLAN ONLY. Nothing here has been executed against production. Evidence is read-only production
state on 2026-10-22 (project `tcxvcatsqqertcnycuop`); counts are snapshots.

## 1. Gates and order (each gate needs its own approval)

| # | Step | Mutates production | Precondition |
| --- | --- | --- | --- |
| 1 | Review and merge the case-level receipt governance PR (migration `20261022130000`) | no | exact-head CI green, code-owner approval |
| 2 | Protected migration release of `20261022130000` | yes (DB) | step 1, `supabase-production` approval, ledger parity |
| 3 | Dead-letter job `8803fe46` (section 3) | yes (one job row) | explicit operator approval |
| 4 | Merge this release-preparation PR | no | exact-head CI green, code-owner approval |
| 5 | Preflight `deploy=false` for the exact main SHA | no | step 4 |
| 6 | Deploy `deploy=true` in `supabase-production` | yes (Edge Function) | steps 2, 3, 5, explicit approval |
| 7 | Post-deploy checks (section 5) | no | step 6 |

Why steps 2 and 3 come before step 6:

- Autonomous non-order receipts are already produced at database level. `whatsapp_materialize_packet_ai_case()`
  calls `whatsapp_apply_non_order_case_governance_v1()` independently of the worker version, and 57 provider
  accepted receipts exist (all `UNKNOWN_EXTERNAL` recipients). The candidate worker calls the same RPC from two
  more places, so the receipt policy must be live before any additional worker traffic.
- The deploy job's idle smoke check is non-mutating: it sends `{"claim_next":true}` without valid credentials,
  expects `401` twice (no token, invalid JWT) and records `NON_MUTATING_NO_CLAIM_EXECUTED`; it never claims work.
  The legacy job `8803fe46` (about 5,000 attempts) would instead be re-attempted by ordinary authenticated
  consumer traffic once the new worker is live, and with the 32-message ceiling the candidate would fetch 18
  expired media links on every attempt, so it is quarantined first.

## 2. Verified release binding

| Item | Value | How verified |
| --- | --- | --- |
| Live worker | v20, `ezbr_sha256` `4fa4639f8c0db5e3d1447e3b4d9e2a1f2ea2e8d382ce1adca1e6637a0bec9d99`, `verify_jwt=true` | Supabase function listing, read-only |
| Candidate source closure | `b18cd2eb890021295861c2ab7c73ba7adec97221a3651aca6fd62dba10b7863c`, 6 files | CI evidence run `39808077192` (PR #441) and an independent local `scripts/edge-function-source-manifest.py` run on `main` at `51ea3f8` |
| Historical v20 closure | `a220be24c6f233c92f1e5e16d21fe593071fe58d3d071e169c733d5564ab1b82` | kept only for the `certify_existing` path (release SHA `e9ba0fc9`) |
| Required migrations in production | `20261022120000`, `20261022121000` present in the ledger | `list_migrations`, read-only |
| Release SHA | the exact `main` commit approved at step 5; the workflow requires 40 hex chars and ancestry of `origin/main` | workflow input |

If any of the six closure files change before release, recompute the closure and update
`CANDIDATE_WORKER_CLOSURE_SHA256` together with the shell governance check and the Python regression.

## 3. Disposition of job `8803fe46-373d-49dc-aad1-19bf8ba02daa`

Evidence (13:14 UTC): state `RETRY`, 5,001 attempts, `last_error_code = INTERPRETATION_PACKET_TOO_LARGE`,
packet `55f8c388-4341-4648-b3ed-24be2ba740f0` revision 18, 18 inbound images, all media links expired on
2026-09-22 (06:41-06:45 UTC), no interpretation row, no outbox row, case `UNCLASSIFIED/NEEDS_IDENTITY`,
`bounded_retry = false` (legacy job). The images cannot be fetched, so neither a requeue nor the 32-message
worker can ever succeed. The only coherent disposition is a governed operator quarantine and a human decision
whether to ask the sender to resend.

Eligibility predicate (the RPC's own, restated):

```sql
select id from public.whatsapp_packet_ai_dispatch_jobs
where id = '8803fe46-373d-49dc-aad1-19bf8ba02daa'
  and (state in ('QUEUED','RETRY','BLOCKED_KNOWLEDGE_AUTHORITY')
       or (state = 'LEASED' and lease_expires_at <= statement_timestamp()));
```

Before (read-only; capture the output as evidence):

```sql
select id, state, attempt_count, bounded_retry, retry_budget_used, last_error_code, packet_revision,
       lease_expires_at, dead_lettered_at, dead_letter_class
from public.whatsapp_packet_ai_dispatch_jobs where id = '8803fe46-373d-49dc-aad1-19bf8ba02daa';
select count(*) as interpretations from public.whatsapp_packet_ai_interpretations
where packet_id = '55f8c388-4341-4648-b3ed-24be2ba740f0';
select count(*) as outbox_rows from public.whatsapp_operator_reply_outbox
where packet_id = '55f8c388-4341-4648-b3ed-24be2ba740f0';
select count(*) as inbound_messages from public.whatsapp_messages
where packet_id = '55f8c388-4341-4648-b3ed-24be2ba740f0' and direction = 'inbound';
```

Execution (service role, one transaction; `<operator>` is a real `users.id`):

```sql
begin;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.dead_letter_whatsapp_packet_ai_dispatch_job(
  '8803fe46-373d-49dc-aad1-19bf8ba02daa',
  'Media links expired 2026-09-22; unrecoverable. Sender to be asked to resend after human triage.',
  '<operator>', 'wa-release-04:8803fe46');
-- expect: true. false means not eligible (for example an unexpired lease): roll back and retry later.
commit;
```

After (expected: one row each; everything else unchanged):

```sql
select state, dead_letter_class, dead_lettered_at, dead_letter_reason
from public.whatsapp_packet_ai_dispatch_jobs where id = '8803fe46-373d-49dc-aad1-19bf8ba02daa';
-- DEAD_LETTERED / OPERATOR_QUARANTINE
select event_type, actor_type, created_at from public.whatsapp_packet_ai_dispatch_dead_letter_events
where job_id = '8803fe46-373d-49dc-aad1-19bf8ba02daa';
-- OPERATOR_DEAD_LETTERED
select count(*) from public.dead_letter_entries
where source_table = 'whatsapp_packet_ai_dispatch_jobs'
  and source_record_id = '8803fe46-373d-49dc-aad1-19bf8ba02daa' and status = 'open';
-- 1
```

Repeat the "before" counts: messages, interpretations and outbox rows must be identical, and no message, case,
potential order or outbound row is created. The call is idempotent per key.

Rollback limits: `requeue_whatsapp_packet_ai_dispatch_job(job, reason, operator, key)` restores the job to the
queue and resets its budget, but it cannot restore the expired media, so the job would fail again. The dead-letter
event is append-only and is never deleted. Do not requeue. Contacting the sender is a separate human decision.

## 4. Historical receipts (read-only, no action)

`disposition_historical_gate3_stale_autonomous_receipts()` quarantines every autonomous
`core-c:non-order-receipt:*` outbox row in `QUEUED`, `SENDING` or `FAILED_RETRYABLE` with no provider id. It
excludes `ACCEPTED`, `DELIVERED`, `READ`, `QUARANTINED`, `FAILED_FINAL`, `CANCELLED` and `ACCEPTANCE_UNKNOWN`,
and it never touches provider ids, events or audit lineage. Cautions:

- It is not time-bounded despite its name: run now or later it would also quarantine a fresh legitimate queued
  receipt. Currently 0 rows are eligible (127 receipts: 57 `ACCEPTED`, 70 `QUARANTINED`), so it is a no-op and
  must not be run.
- It includes `SENDING`, so a row mid-send could be quarantined while the provider call is in flight.

Accounting for the seven receipts on the four packets (all `ACCEPTED`, all `UNKNOWN_EXTERNAL`, none delivered
or read):

| Packet | Receipts | Created | Note |
| --- | --- | --- | --- |
| `b87a642a` | 2 | 2026-10-05 14:27, 2026-10-22 10:02 | second is a stale replay |
| `814a6c76` | 2 | 2026-10-05 14:49, 2026-10-22 10:02 | second is a stale replay |
| `da794d6c` | 2 | 2026-10-21 04:46, 2026-10-22 10:04 | second is a stale replay |
| `b5e1d52d` | 1 | 2026-10-22 10:02 | only receipt, stale replay (last message 2026-10-13) |

Four were created on 2026-10-22 by the replay; they are provider-accepted and are preserved as history.

## 5. Post-deploy checks (no customer-facing action)

- `verify_jwt = true`, `status = ACTIVE`, `version > 20`, deployed closure `b18cd2eb...` (workflow does this).
- Unauthenticated and wrong-key calls rejected (workflow smoke checks).
- Job states and `last_error_code` distribution unchanged for jobs other than `8803fe46`.
- `select count(*) from whatsapp_operator_reply_outbox where created_at > <deploy time>` equals the number of
  governed receipts the new policy allows; no `STALE_REPLAY` or `CASE_RECEIPT_ALREADY_SENT` case should yield a row.
- No new `sales_order` or `whatsapp_potential_orders.sales_order_id` appears.

## 6. Rollback

- Edge Function: the workflow checks that live equals `EXPECTED_LIVE_VERSION`, so after a v21 deploy it cannot simply
  be re-run for v20. Rollback is a reviewed pin flip through the same protected workflow: set `EXPECTED_LIVE_VERSION`
  and `EXPECTED_LIVE_BUNDLE_SHA` to the deployed version, set `CANDIDATE_WORKER_CLOSURE_SHA256` to
  `a220be24...`, and dispatch with release SHA `e9ba0fc9ede29760ef503eb9fb474a01a8a17ca5` (an ancestor of `main`),
  then preflight and deploy as in section 1. The preflight also stores `live-v<EXPECTED_LIVE_VERSION>-source-manifest.json` and
  `whatsapp-packet-ai-worker-predeploy-v<EXPECTED_LIVE_VERSION>.tar.gz` as the pre-deploy source evidence for that rebuild.
- Pre-deploy rollback evidence is fail-closed. The capture computes the closure from the recursive import graph of the
  downloaded source and then re-extracts the archive to verify its file set, every file hash and size, and the closure.
  A missing local import fails the preflight; the live bundle hash is never reported as a closure. The platform source
  API omits `whatsapp-content-interpret/types.ts` for v20 (`sanitize.ts` imports it with `import type`, which the
  bundler erases), so the capture restores that single file from the commit pinned in
  `scripts/lib/whatsapp-packet-ai-worker-v20-rollback-completion.json`, after proving that every file the platform did
  return is byte-identical to that commit. The manifest labels it `pinned_historical_git`: it is rollback material,
  not live-source evidence. The five-file closure plus that file reproduces `a220be24...`.
- Database: forward-only. Migration `20261022130000` is additive (functions replaced, no data changed); to revert
  behaviour ship a reviewed forward migration that restores the previous function bodies. Never rewrite migration history.
