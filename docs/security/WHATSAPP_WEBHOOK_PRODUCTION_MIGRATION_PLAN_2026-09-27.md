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
2. checked-out commit exactly matches the operator-supplied `release_sha`;
3. target project ref is exactly `tcxvcatsqqertcnycuop`;
4. current live function is still version `167`, status `ACTIVE`,
   `verify_jwt=false`, and has the exact recorded pre-deploy bundle hash;
5. Core Edge governance and WhatsApp recertification guard pass;
6. the protected production migration prerequisite run and its immutable deployment
   artifact are still present and successful; the webhook workflow receives no
   `SUPABASE_DB_URL` or other direct production database write credential;
7. no production secret values are read, printed, rotated, or modified;
8. the deployment command names only `whatsapp-webhook`;
9. the production write job is protected by the `supabase-production`
   GitHub Environment approval gate.

Any failed condition is NO-GO.

## Deployment

The only authorized mutation is the named function deployment from the exact reviewed
Core commit:

`supabase functions deploy whatsapp-webhook --project-ref tcxvcatsqqertcnycuop --no-verify-jwt`

No other function may be deployed by this workflow.

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
to hide the failure. Stop outbound/automation exposure if required and redeploy the
captured pre-deploy v167 source snapshot under a separately reviewed rollback action.

## Post-deploy smoke checks

The workflow may perform only non-customer, non-secret-bearing negative tests:

- function remains `ACTIVE`;
- deployed version advances beyond 167;
- `verify_jwt=false` remains unchanged;
- GET challenge without a valid token returns 403;
- unauthenticated POST returns 401 before privileged processing;
- no broad function deployment occurred.

Positive provider certification is evidence-driven after deployment:

- naturally occurring valid Click2API callback accepted;
- nested Meta status callback acknowledged;
- delivery/read callback updates the governed outbox through the atomic RPC;
- invalid/missing auth remains rejected;
- production logs contain no raw secret/token logging;
- duplicate provider message behavior remains idempotent.

No synthetic customer message is required merely to close this gate.

## Owner authorization boundary

Repository policy still requires explicit owner authorization in the active conversation
for the exact production Edge Function deployment. Merge of this plan/workflow is not
itself permission to deploy.

After that authorization, run the dedicated `WhatsApp Webhook Production Release`
workflow against the exact current Core `main` SHA with `deploy=true`.
