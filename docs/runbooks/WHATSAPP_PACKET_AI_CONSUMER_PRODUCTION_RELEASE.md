# WhatsApp packet AI consumer: protected production release (Core #454)

`whatsapp-packet-ai-consumer` is the only function the pg_cron `whatsapp-packet-ai-consumer-minute` job calls. It imports
the worker in-process, so the worker bundle in the consumer is frozen at the consumer's last deploy. Releasing the worker
workflow alone never repairs the consumer.

## Why this lane exists
Production consumer v5 bundled a worker that treated an all-NULL claim row (an idle queue) as `DISPATCH_CLAIM_INVALID`, so
every scheduled tick returned HTTP 502. `main` already contains the correction (`isEmptyClaimRow`), but no protected workflow
deployed the consumer.

## Controls (all fail closed)
| Control | Where |
| --- | --- |
| Manual dispatch only; exact 40-hex `release_sha` that is an ancestor of `origin/main`, checked at preflight and again at deploy | workflow |
| Pinned live baseline (version 5, bundle `6132d9ed…`, `verify_jwt=false`), asserted at preflight and immediately before deploy | workflow env |
| Pinned complete bundled closure (`CANDIDATE_CONSUMER_CLOSURE_SHA256`), asserted at preflight and at deploy | workflow env |
| Restorable pre-release capture of live v5 (`…-predeploy-v5.tar.gz` + manifest), type-only module completed from the pinned record | `scripts/lib/whatsapp-packet-ai-consumer-v5-rollback-completion.json` |
| Read-only preflight **and dependent postverification** in `supabase-production-readonly`; API-only deploy in `supabase-production` (human approval). Protected deploy has no database URL | environments |
| Exactly one named deploy; `--no-verify-jwt` for this function only; metadata must report `verify_jwt=false` | workflow |
| Deployment-time signed source attestation, then `VERIFIED` or `VERIFIED_BY_ATTESTATION` (never `INDETERMINATE`) | workflow |
| Non-mutating smoke: non-POST 405, missing secret 401, wrong secret 403. The real consumer secret is never read or sent; no claim is executed | workflow |
| Read-only runtime SQL (catalog, RPC/grant checks, migration ledger under restricted DB credentials); independent authorized read-only confirmation of cron command and Vault secret names required before deployment | `scripts/sql/verify-whatsapp-packet-ai-consumer-production-runtime.sql` |
| Before/after PostgreSQL cumulative table-DML counters under restricted DB credentials; any gated counter change fails closed and a changed `relfilenode` (bulk clear or table rewrite, which row-delete counters do not see) also fails (coarse telemetry, not row-level proof) | `scripts/sql/snapshot-…sql`, `scripts/whatsapp-packet-ai-consumer-release-evidence.py` |
| At least 15 consecutive healthy minutes (HTTP 200, `success`, `idle`, `processed=0`, `failed=0`, `errors=[]`); any `DISPATCH_CLAIM_INVALID` after the release is an immediate failure | `scripts/observe-whatsapp-packet-ai-consumer-ticks.sh` |

## What this release changes in production
The consumer is rebuilt from `main`, so it also takes the newer worker, sanitizer, media-fetch and provider code
(worker Phase 2 from Core #448). The worker function itself (v21) is a separate bundle and stays on its own release lane; until
it is released the two functions run different worker revisions. The database migrations the new code needs are already
applied (`20261022120000`, `20261022121000`, `20261024130000`; asserted by the runtime SQL).

## Procedure
1. Merge the release PR (owner, Core Main Protection). Merging does not deploy.
2. Dispatch **WhatsApp Packet AI Consumer Production Release** with `deploy=false`, `observe_only=false`, `release_sha=<main SHA>`.
   Preflight is read-only and uploads the rollback capture.
3. Dispatch again with `deploy=true`. The named-function API-only `deploy` job waits for the `supabase-production` approval; approve only after reading the preflight evidence.
4. The deployment job signs/verifies its source provenance and performs non-mutating auth smoke checks, then uploads **provisional** evidence. It receives no database URL; the existing production environment's database credentials remain unchanged for migration workflows.
5. The dependent `postverify` job runs in `supabase-production-readonly`. It downloads only immutable evidence from the same workflow run, binds its DB login to `oasis_drift_watch_ro`, rechecks the live function metadata, compares preflight vs immediate-after change telemetry, certifies runtime SQL, observes at least 15 healthy minutes, compares final telemetry and signs the final release certificate. **Only a green entire workflow certifies the software release.** A red postverification after a green deploy means deployment happened but certification failed; follow the governed recovery procedure, never claim the module is fully certified.
6. `observe_only=true` re-runs just the read-only observation (for example to repeat the 15-minute proof later).

## Rollback
The preflight artifact `whatsapp-packet-ai-consumer-production-preflight-<sha>-<attempt>` holds the verified live v5 source
(`whatsapp-packet-ai-consumer-predeploy-v5.tar.gz`) and its manifest. That artifact is forensic and last-resort material: v5
returns HTTP 502 on every idle tick, so it is not a recovery target while the queue is idle.

Rolling back means a reviewed recovery commit on `main` that keeps the all-NULL idle handling (for example a revert of only
the offending later change), released through this same lane. The PR updates `EXPECTED_LIVE_VERSION`,
`EXPECTED_LIVE_BUNDLE_SHA`, `CANDIDATE_CONSUMER_CLOSURE_SHA256` and the matching rollback completion pin to the then-live
release. The governance checker (`scripts/check-whatsapp-packet-ai-consumer-production-release.sh`) hardcodes the same live
version and bundle hash, both in its workflow assertions and in its rollback-pin validation, so the recovery PR must update
the checker too, and its regression (`scripts/tests/verify-check-whatsapp-packet-ai-consumer-production-release.sh`) must still
show that the checker accepts the new baseline and rejects a mismatch. Redeploying the captured v5 source is acceptable only if the owner explicitly accepts a failing idle tick (for
example while the cron is paused through a governed change), and it too goes through this lane. Never use a manual dashboard
edit, `mcp deploy_edge_function`, or disabling the cron outside governance.

## Database access of the release workflow
The read-only environment's `SUPABASE_DB_URL` is the least-privilege `oasis_drift_watch_ro` role. The protected `supabase-production` deploy job does **not consume any database URL**, avoiding its separate, potentially privileged migration credentials. The restricted role can read the catalog, the migration
ledger, `net._http_response` and the per-table row-change statistics. It cannot read the `cron` or `vault` schemas or any business
table, and the release must not need to. That is why the runtime SQL checks catalog objects, grants and the ledger only, why the
change-detection gate compares cumulative statistics counters and `relfilenode` (not transactionally consistent row snapshots), and why the number of consumer results expected per minute is a pinned
workflow value (`OBSERVE_EXPECTED_PER_MINUTE`) rather than a query. Governance rejects `cron` or `vault` access in these files.

## Evidence limits
* The workflow pins the database login's effective `current_user` to `oasis_drift_watch_ro` in preflight, postverification and independent read-only observation; a mismatched principal fails closed. The protected deployment job never connects to the database.
* Preflight-to-postdeploy comparisons span the owner's protected approval wait; unrelated legitimate processing during that wait can cause a fail-closed certification result. Postverification does not retroactively prove transaction-level pre-deploy state, and the direct authorized business-state audit remains required.
* The deploy job uploads provisional evidence even if an earlier step fails; this artifact is **not** a software release certification. The final attestation is generated only by the successful downstream restricted postverification job.
* PostgreSQL's cumulative `pg_stat_user_tables` counters are **not synchronous, immutable or row-level evidence**. A passing counter comparison is a conservative change-detection gate, **not proof that no business rows changed**. A separately authorized, read-only production audit should compare relevant business-table state and dispatch/outbound/dead-letter identities around release; if that evidence is unavailable, classify exact data-integrity certification as pending, not PASS.
* The `OBSERVE_EXPECTED_PER_MINUTE=2` pin is an assumption, not a live cron read by the restricted role. The observer additionally validates that its effective runtime environment value is exactly two, so shell/job/step overrides to one fail closed. Before an approved deployment, an independent authorized auditor must confirm the *exact* packet-AI job name, active flag, every-minute schedule, tick function command, operator-reply consumer job, and both required Vault secret **names only**. If they disagree, do not deploy; submit a reviewed repair rather than bypass the restricted role.
* The 15-minute mixed `pg_net` response proof is insufficient for per-function attribution by itself. Independently cross-check Supabase Edge request logs for the identical interval: each scheduled `whatsapp-packet-ai-consumer` request must be HTTP 200 (not 502), with no `DISPATCH_CLAIM_INVALID` events. Do not claim module/provider certification without consented live sending and delivery callbacks.
* Observation reads `net._http_response`, which also records the operator-reply consumer's ticks. A minute is healthy only
  when every consumer result in it is healthy and the count equals the active consumer cron jobs, so a busy reply consumer
  can delay (not falsify) the proof. Re-run `observe_only` if that happens.
* The observation SQL takes no parameter: it returns the last three hours of recorded responses and the evaluator applies the
  release instant. A release older than that window would show its early ticks as missing, which fails closed.
* `net._http_response` does not store the destination or the originating request id, and the tick function does not
  persist the id it receives, so a response cannot be tied to the packet-consumer cron job directly. To keep that from
  producing a false pass, a minute counts only with exactly the expected number of consumer-shaped results, all healthy;
  any surplus makes the minute unattributable. A minute is judged only after it has closed (20 s grace), so a missing or
  short final minute resets the run.
* Edge logs for the function remain the per-function cross-check and are queried read-only outside the workflow.
* Passing this lane certifies the idle path in production. It does not certify real job processing, customer delivery or
  provider callbacks; those need the consented-recipient governed test.
