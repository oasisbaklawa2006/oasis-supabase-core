# WhatsApp Webhook Governed Production Migration Plan — 2026-09-27

## Purpose

This is the explicit ERP webhook migration plan required by `FUNCTION_OWNERSHIP.md`
for the high-risk production Edge Function `whatsapp-webhook`.

It authorizes only a dedicated, approval-gated release of the canonical Core source.
It does not authorize broad Edge deployment, secret mutation, callback-URL mutation,
or deployment from AI Studio/Central.

## Canonical production target

- Supabase project: `tcxvcatsqqertcnycuop`
- Function: `whatsapp-webhook`
- Runtime auth mode: `verify_jwt=false` retained intentionally because the function
  performs provider-specific authentication before privileged processing.
- Pre-deploy production baseline observed read-only:
  - version: `167`
  - status: `ACTIVE`
  - bundle SHA-256:
    `8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426`
- Target source: exact protected Core `main` SHA supplied to the dedicated workflow.
- Database prerequisite:
  - `20260927120000_b2b_read_grant_uat52_repair` live
  - `20260927132000_fl_sup_01_support_queue_operator_rls` live
  - protected Production Migration Release run `36335058964` completed successfully at
    Core SHA `f3366a4a99b57e20ec47a4f152af3a7b3661f5c6`
  - immutable deployment artifact
    `production-migration-deployment-f3366a4a99b57e20ec47a4f152af3a7b3661f5c6`
    retained through the release window

## Why this deployment is required

The production v167 source predates the current canonical Core boundary and still uses
the prior provider-status reconciliation path. Current Core carries reviewed forward
hardening including:

- authenticated raw-request boundary before JSON parsing or side effects;
- verified GET challenge handling;
- no wildcard browser CORS surface;
- durable fail-closed inbound persistence;
- governed company resolution without fuzzy cross-company auto-linking;
- permanent quarantine of legacy webhook order writes;
- no invented quantity fallback;
- atomic provider delivery/read persistence through
  `persist_whatsapp_operator_reply_provider_status`;
- explicit CI path detection for the provider-status helper and tests.

The database half of the atomic provider-status change is already production-live;
the Edge Function release is therefore the remaining runtime half.

## Non-negotiable preflight

The dedicated workflow must fail closed unless all of the following are true:

1. branch is `main`;
2. checked-out commit exactly matches the operator-supplied `release_sha`, and that
   SHA is still the current remote `main` immediately before both preflight and
   production mutation;
3. target project ref is exactly `tcxvcatsqqertcnycuop`;
4. current live function is still version `167`, status `ACTIVE`,
   `verify_jwt=false`, and has the exact recorded pre-deploy bundle hash;
5. Core Edge governance and WhatsApp recertification guard pass;
6. the protected production migration prerequisite run and its immutable deployment
   artifact are still present and successful; the webhook workflow receives no
   `SUPABASE_DB_URL` or other direct production database write credential;
7. required provider/function secret **names** are verified read-only:
   `WHATSAPP_WEBHOOK_VERIFY_TOKEN`, `CLICK2API_API_KEY`, and at least one of
   `WHATSAPP_META_APP_SECRET` / `WHATSAPP_APP_SECRET`; their values are never
   read, printed, rotated, or modified. The workflow necessarily uses the protected
   `SUPABASE_ACCESS_TOKEN` management credential for read-only metadata checks and
   the named Edge deployment;
8. generated release evidence is scanned to ensure the Supabase access token itself
   is never persisted into workflow artifacts;
9. the deployment command names only `whatsapp-webhook`;
10. the production write job is protected by the `supabase-production`
    GitHub Environment approval gate;
11. a deterministic manifest of the reviewed local source closure is generated before
    deployment and preserved as release evidence; and
12. the deployment is not considered successful until the live function can be
    downloaded again and its local source closure exactly matches the reviewed
    source manifest.

Any failed condition is NO-GO.

## Deployment

The only authorized mutation is the named function deployment from the exact reviewed
Core commit:

`supabase functions deploy whatsapp-webhook --project-ref tcxvcatsqqertcnycuop --no-verify-jwt`

No other function may be deployed by this workflow.

The workflow produces a deterministic source-closure manifest from the exact reviewed
Core SHA. After deployment, the live function is downloaded through the pinned Supabase
CLI and independently manifested. A byte-level hash mismatch in any local module in the
closure fails the release. A successful workflow therefore attests not only that a new
version exists, but that the deployed local source is the reviewed source.

## Recovery point

Immediately before deployment, the workflow captures:

- live function metadata;
- a restorable source snapshot downloaded by the pinned Supabase CLI into an
  isolated temporary tree; the complete downloaded `supabase/functions` tree
  (including shared dependencies) is archived as a validated tar.gz; the known
  v167 entrypoint and `_shared/click2apiWebhookAuth.ts` dependency must both be
  present before the archive is accepted;
- exact Core release SHA;
- pre-deploy function version and bundle hash;
- SHA-256 of the rollback source archive.

The live function metadata is fetched again after source capture and again
immediately before deployment. Any baseline change is a NO-GO. The rollback
snapshot and context are validated and uploaded as immutable workflow evidence
before the deploy command is allowed to execute.

If the post-deploy smoke test fails, do not alter provider secrets or callback routing
to hide the failure. Stop outbound/automation exposure if required and use the dedicated
`.github/workflows/whatsapp-webhook-production-rollback.yml` lane.

The rollback lane is deliberately separate from the forward release. It requires:

- the original forward-release workflow run ID, run attempt, and exact release SHA;
- the exact currently live function version and bundle SHA before rollback;
- the immutable rollback artifact captured before the forward deployment;
- a second `supabase-production` environment approval;
- exact current-live-state revalidation immediately before rollback;
- a literal named `whatsapp-webhook` deploy only;
- post-rollback negative authentication smoke checks; and
- source-closure equality between the preserved v167 snapshot and the function
  downloaded again after rollback.

A rollback therefore fails closed if production has moved since authorization or if the
preserved source evidence cannot be proven intact.

## Post-deploy smoke checks

The workflow may perform only non-customer, non-secret-bearing negative tests:

- function remains `ACTIVE`;
- deployed version advances beyond 167;
- `verify_jwt=false` remains unchanged;
- GET challenge without a valid token returns 403;
- unauthenticated POST returns 401 before privileged processing;
- no broad function deployment occurred;
- the downloaded live source closure exactly matches the reviewed release source; and
- a required release attestation artifact records old/new function versions, old/new
  bundle hashes, exact Core SHA, run/attempt identity, and reviewed/live source hashes.

Positive provider certification is evidence-driven after deployment:

- naturally occurring valid Click2API callback accepted;
- nested Meta status callback acknowledged;
- delivery/read callback updates the governed outbox through the atomic RPC;
- invalid/missing auth remains rejected;
- production logs contain no raw secret/token logging;
- duplicate provider message behavior remains idempotent.

No synthetic customer message is required merely to close this gate.

## Permanent CI invariants

The release/rollback mechanism is itself governed by
`scripts/check-whatsapp-webhook-production-release.sh`, which is executed from
Edge Function Governance. The guard fails if future changes introduce an automatic
production trigger, broaden the deploy target, add production DB/secret mutation
authority, remove the shared release/rollback concurrency lock, remove source
attestation, weaken rollback evidence, or bypass the protected production environments.

`scripts/detect-pr-edge-governance-paths.sh` explicitly includes both production
workflow files and their guard/helper scripts so later edits cannot silently bypass the
Edge governance workflow.

## Owner authorization boundary

Repository policy still requires explicit owner authorization in the active conversation
for the exact production Edge Function deployment. Merge of this plan/workflow is not
itself permission to deploy.

After that authorization, run the dedicated `WhatsApp Webhook Production Release`
workflow against the exact current Core `main` SHA with `deploy=true`.

If rollback is required, do not reuse the forward workflow or manually redeploy files.
Use only the dedicated rollback workflow with the exact source-run evidence and exact
currently live version/hash inputs, then pass the independent production environment
approval gate again.
