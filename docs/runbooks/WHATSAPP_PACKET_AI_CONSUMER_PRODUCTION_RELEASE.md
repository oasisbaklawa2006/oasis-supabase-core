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
| Read-only preflight in `supabase-production-readonly`; deploy only in `supabase-production` (human approval) | environments |
| Exactly one named deploy; `--no-verify-jwt` for this function only; metadata must report `verify_jwt=false` | workflow |
| Deployment-time signed source attestation, then `VERIFIED` or `VERIFIED_BY_ATTESTATION` (never `INDETERMINATE`) | workflow |
| Non-mutating smoke: non-POST 405, missing secret 401, wrong secret 403. The real consumer secret is never read or sent; no claim is executed | workflow |
| Read-only runtime SQL (catalog, grants, cron, vault secret names only, migration ledger) | `scripts/sql/verify-whatsapp-packet-ai-consumer-production-runtime.sql` |
| Before/after state snapshots; job states, dead letters and outbound attempts must be unchanged | `scripts/sql/snapshot-…sql`, `scripts/whatsapp-packet-ai-consumer-release-evidence.py` |
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
3. Dispatch again with `deploy=true`. The `deploy` job waits for the `supabase-production` approval; approve only after reading the preflight evidence.
4. The deploy job observes ticks itself. A red run after deploy means the release is not certified; use the rollback below.
5. `observe_only=true` re-runs just the read-only observation (for example to repeat the 15-minute proof later).

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

## Evidence limits
* Observation reads `net._http_response`, which also records the operator-reply consumer's ticks. A minute is healthy only
  when every consumer result in it is healthy and the count equals the active consumer cron jobs, so a busy reply consumer
  can delay (not falsify) the proof. Re-run `observe_only` if that happens.
* `net._http_response` does not store the destination or the originating request id, and the tick function does not
  persist the id it receives, so a response cannot be tied to the packet-consumer cron job directly. To keep that from
  producing a false pass, a minute counts only with exactly the expected number of consumer-shaped results, all healthy;
  any surplus makes the minute unattributable. A minute is judged only after it has closed (20 s grace), so a missing or
  short final minute resets the run.
* Edge logs for the function remain the per-function cross-check and are queried read-only outside the workflow.
* Passing this lane certifies the idle path in production. It does not certify real job processing, customer delivery or
  provider callbacks; those need the consented-recipient governed test.
