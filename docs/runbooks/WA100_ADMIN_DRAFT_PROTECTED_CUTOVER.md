# WA-100 — protected Core admin-create-draft no-send cutover

**Status: source-only draft; no production deploy authorized.**
Owner: WA-100 / Core #450. The candidate was source-merged in Core #549. The new workflow is a separate, **manual** release gate; merging it does not invoke any production operation.

## Evidence and authority

- Protected Core repo: `oasisbaklawa2006/oasis-supabase-core`.
- Production Supabase project: `tcxvcatsqqertcnycuop`.
- Observed live `admin-create-draft` baseline: **v112**, `ACTIVE`, `verify_jwt=false`, SHA-256 `4250a5d73775e7da4c1bdb8320acc039eafc703077b0f67e82f1aee01cfa17d2`.
- New canonical Core source: `supabase/functions/admin-create-draft/index.ts` (source-only #549 merge `f4012757b0ccac90d1aec9a5ff483a86345deadf`). It preserves the administrator token/role checks and the draft / WAMID behaviors, but never directly invokes `send-whatsapp`. A requested notification is `NOT_SENT_RELEASE_GATED`, **not queued, accepted or delivered**.
- Linked Central Shadow Client caller currently supplies legacy `send_whatsapp_to` and `whatsapp_message` parameters. Central PR #673 removes the untrusted arbitrary-recipient request and shows no-send explicitly; Central #674 already removed two other direct automatic sends, while #676 is a distinct dispatch gate. Coordinate release order and user training with Central operators.
- The old production function used `verify_jwt=false` plus `auth.getUser(token)` and checks `ADMIN` / `SUPER_ADMIN`. This release deliberately retains the same gateway posture by supplying `--no-verify-jwt`; it does **not** grant anonymous order creation. Enabling gateway JWT validation must be separately tested for legacy admin/War Room clients.

## Before requesting any production cutover

1. Independent CODEOWNER/security review of this release workflow, #549 source and Central #673 caller impact. Require exact-head CI and any mandatory security checks.
2. Confirm operators understand that a draft/order save **no longer sends** the optional WhatsApp confirmation; an operational follow-up procedure and truthful UI notice are mandatory before cutover. Confirm rollback owner and UAT test identities. Do not create an alternative direct sender.
3. Validate the current production baseline still matches the pinned version, bundle SHA and JWT posture. If it has changed, **stop** and produce a newly reviewed preflight pin. Never silently update the pin.
4. Verify no arbitrary external WhatsApp send is expected from `admin-create-draft`; inspect the Shadow Client and other Central usages. Maintain approved client-business workflows and physical operations.
5. Independently approve the `supabase-production` GitHub environment. Owner input flags are declarations, **not substitutes** for the environment's reviewer approval.

## Safe sequence

1. After reviewed workflow merge into protected `main`, dispatch `WA-100 Admin Draft Protected Cutover` on **main**, input exact current 40-character SHA, `deploy=false`. Run credential-free contract, read-only `supabase-production-readonly` preflight, baseline check and archived v112 source capture.
2. Verify the immutable preflight artifact: live v112 metadata and complete one-file downloaded source; candidate hash; archived source checksum. Keep source archive access-controlled and do not post into public comments.
3. Only after Central caller cutover/notice and safe recovery owner are signed, dispatch an independently reviewed current-main SHA with `deploy=true`, `central_caller_certified=true`, `rollback_approved=true`. The environment **`supabase-production`** requires separate human approval.
4. The production job repeats exact main SHA, source checksum, prior archive checksum and **live v112 hash/version** check immediately before any write. It deploys **only** `admin-create-draft`, preserving `verify_jwt=false`. No migration, blanket function deployment, OTP edit or message traffic is authorized.
5. Verify live version strictly newer than 112, `ACTIVE`, JWT posture still false, downloaded new function source byte-identical to reviewed Core candidate; anonymous and invalid bearer POSTs both fail with HTTP 401. Separately perform consented ADMIN/SUPER_ADMIN and non-admin UAT against isolated test data, ensure order/WAMID idempotency and no provider message, and inspect `orders`, `whatsapp` outbox/provider logs for unintended sending. If any proof is missing, keep final certification NO-GO.

## Failure and recovery

- Read-only preflight failure, candidate-source mismatch, live-baseline drift, incomplete archive, missing Central/owner signoff or failed environment approval: **stop without deploy**. Do not override checks.
- A post-deploy failure is an incident. Record live version, source, function invocation status and customer impact. Do **not** automatically restore v112: it contains the ungoverned optional external WhatsApp send. Prefer the separately authorized safe Core candidate or a reviewed corrective patch through this protected lane. Reenable historical sends only after independent consent/idempotency and release authority.
- No automatic replay of `FAILED`, `QUARANTINED` or `ACCEPTANCE_UNKNOWN` outbox rows, no fabricated provider IDs or `DELIVERED` claims.
- This workflow intentionally **does not** resolve separate OTP retirement #543, WA migration chronology #536/#537, outbound order-command foundation #550, Click2API HTTP 401 or final new-consent `DELIVERED` proof.

**Protected release stays NO-GO until independently approved, deployed, verified and operator UAT-certified.**
