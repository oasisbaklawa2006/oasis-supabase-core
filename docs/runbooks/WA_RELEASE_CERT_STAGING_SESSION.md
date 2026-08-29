# WhatsApp Release Certification — Isolated Staging Session

This branch exists only to provision and certify an isolated Supabase preview environment for the WhatsApp release-certification programme.

## Authority

- Canonical Core main (Gate 0 refresh): `d74e0b865b9a5b7c419388fa8a1550f03cb5d3db`
- Core main after Stage-1 ingress repair: `fab554fea099c7f8a3ea7f1aeb71af5fc5fd42b6` (#128 merge)
- Prior certification base (stale): `f8a850c39e5662d9ada5d16c30682d4ae2e2f516`
- Certification branch: `cert/wa-release-cert`
- Certification PR: `#126`
- Isolated Supabase preview project: `dfjslkwxawnzurolifpm`
- Production project: `tcxvcatsqqertcnycuop`
- Preview is `with_data=false`; production data is not copied.
- Production must remain untouched.

## Gate 0 authority refresh (2026-08-27)

Commits since stale certification base `f8a850c39e5662d9ada5d16c30682d4ae2e2f516` through current Core main:

| SHA | Summary |
|---|---|
| `d74e0b8` | PF-4: canonical SO commercial snapshots and versioning (#125) |

**WhatsApp certification impact: YES.** PF-4 replaces `promote_sales_order_draft_to_order_governed_v1` to route WhatsApp draft promotion through `create_sales_order_commercial_version_v1` and truthful `WHATSAPP` provenance. No WA-1–WA-7 architecture rebuild; promotion/commercial authority path changed and must be re-certified.

**Branch refresh:** `cert/wa-release-cert` rebased onto `d74e0b865b9a5b7c419388fa8a1550f03cb5d3db`. Certification-only runbook/marker preserved; PR #126 not merged into `main`.

**Migration replay:** PASS on Core `main` Migration CI run `33114262144` (clean replay + full pgTAP at `d74e0b8`). Includes PF-4 contract `20260827063731_pre_factory_so_commercial_authority_contract.sql` and WhatsApp autonomy CORE-A/B/C + WA-7 aggregate suites.

**Edge Function deployment:** Preview redeploy triggered by marker refresh on PR #126. `supabase/config.toml` continues to scope preview deploy to approved functions only; production webhook remains undeclared and untouched.

**Production target protections:** `validateCertDatabaseTarget()` still rejects `tcxvcatsqqertcnycuop`; remote certification requires dual opt-in allowlist.

**Minimum smoke (executable evidence via pgTAP on current main):**

| Probe | pgTAP / harness evidence | Result |
|---|---|---|
| Clear employee-mediated order | `20260823100000_whatsapp_autonomy_core_a.sql` TEST 1 | `AUTO_ELIGIBLE` + autonomous promotion |
| Missing quantity | same file TEST 2 | `CLARIFICATION_REQUIRED`, no draft |
| Invented COD / price / discount | `whatsapp_autonomy_gate11_hardening.test.sql` + CERT-A `invented-discount-stripped-master-price-may-auto` | governed terms only; no invention leak |
| Exact replay | CORE-A/B idempotency + CERT-A `duplicate-replay-safe` | no duplicate SO/draft |

**Reconciliation:** WA-7 aggregate `20260813210000_wa7_whatsapp_release_certification.sql` and WA-1 reconciliation view pass in Migration CI (`unaccounted_potential_orders = 0` invariant).

**Open genuine defects:** none identified on current main; PF-4 merged with passing CI.

**Preview refresh:** push to `cert/wa-release-cert` re-triggers Supabase Git preview `dfjslkwxawnzurolifpm` against rebased certification head.

## Stage 1 media ingress repair (#128) — CLOSED on Core main

**PR #128** merged `2026-08-28T05:23:26Z` by owner review. Merge commit `fab554f`; repair head `78fda15`.

**Defect:** empty-body multimodal ingress (`mediaCount > 0`) was terminalized as `FAILED_INTERPRETATION` at capture.

**Repair (narrow scope):**

| File | Change |
|---|---|
| `supabase/functions/_shared/studioInboxFanOut.ts` | `rawTrimmedBody` before placeholder; `awaitingMediaReview` gates `interpretationFailed` |
| `supabase/tests/20260827230000_wa_stage1_media_ingress_certification.sql` | Stage-1 regression pgTAP (`plan(22)`) |

**Invariant restored:** **CAPTURED MEDIA ≠ FAILED INTERPRETATION**

**CI (exact repair head `78fda15`):** Migration run `33142046276` — Stage-1 file **ok**, full pgTAP **1991 PASS**, Edge Function Governance **PASS**, Codacy **0 issues**, CodeRabbit **SUCCESS**.

**Cert branch refresh:** `cert/wa-release-cert` at `f5a3fde` merges merged Core `#128` into certification harness. PR #126 Supabase Preview **SUCCESS** (`dfjslkwxawnzurolifpm`) after refresh.

**Stage-1 pgTAP regression proof (A–F):**

| Case | Result |
|---|---|
| A. Empty body + `mediaCount > 0` | No terminal `FAILED_INTERPRETATION` at ingress |
| B. Pending state | Evidence `PENDING`; packet `AWAITING_MEDIA`; PO `UNASSIGNED` |
| C. Explicit media failure | `TIMED_OUT` / `CORRUPT` → `FAILED_INTERPRETATION` after `complete_whatsapp_media_processing` |
| D. Recovery | `fail_open_media_review` + `SUCCEEDED` → PO `UNASSIGNED` |
| E. Duplicate replay | Idempotent; single evidence row |
| F. Reconciliation | `unaccounted_potential_orders = 0` |

**Remaining Stage-1 work (not started here):** live `whatsapp-packet-ai-worker` recognition on cert preview (Part B) requires `LOVABLE_API_KEY` and sanitized media fixtures against `dfjslkwxawnzurolifpm`. Historical corpus (H1) remains blocked on protected export availability.

**Production:** untouched (`tcxvcatsqqertcnycuop`).

## Stage 1B — actual multimodal worker certification (in progress)

**Scope:** live `whatsapp-packet-ai-worker` on isolated preview `dfjslkwxawnzurolifpm` through Lovable AI Gateway (Gemini multimodal + OpenAI transcription). Not pgTAP-only; not mocked interpretation JSON.

**Harness:** `scripts/whatsapp-stage1b-cert/` on `cert/wa-release-cert` (manifest + fixture generator + `run.ts`). Fixtures generated outside Git under `/tmp/wa-stage1b-cert-fixtures`. Media hosted on cert-preview storage bucket `wa-stage1b-cert` (requires `WHATSAPP_MEDIA_ALLOWED_HOSTS` include `dfjslkwxawnzurolifpm.supabase.co` on preview only).

**Runtime authority (owner-verified):** `whatsapp-webhook` deployed version **154** on cert preview (post-#128 source).

**Required Cloud Agent / CI secrets (names only):**

- `SUPABASE_SERVICE_ROLE_KEY` (cert preview `dfjslkwxawnzurolifpm`)
- `LOVABLE_API_KEY`
- `DATABASE_URL` or `WA_CERT_ALLOW_REMOTE_DATABASE=true` + `WA_CERT_REMOTE_DATABASE_ALLOWLIST` (cert pooler host)
- Optional: `SUPABASE_ACCESS_TOKEN`, `CLICK2API_API_KEY`, `CLICK2API_ACCESS_TOKEN`

**Status:** harness ready; execution **BLOCKED** until cert preview credentials are present in the agent environment. Do not merge PR #126; do not touch production.

## Rules

1. This branch is a certification harness/provisioning branch, not a feature branch.
2. Do not merge this PR into `main` merely to complete certification.
3. Do not point certification scripts at the production database.
4. Any remote database used by CERT-A must pass the merged `validateCertDatabaseTarget()` protections.
5. Historical WhatsApp exports remain outside Git. Only sanitized derived fixtures may be used.
6. Synthetic CERT-A remains a safety regression harness; representative historical traffic is the source for real straight-through/accuracy measurement.
7. Required release evidence remains: protected historical benchmark, cross-repo staging E2E, reliability/load/chaos/reconciliation, real provider proof, final release ledger.
8. Production deployment requires separate explicit authorization.

## S0 provisioning evidence

- Initial manually-created branch failed historical parent replay and was deleted; it is not a certification target.
- PR-linked preview `dfjslkwxawnzurolifpm` reached `ACTIVE_HEALTHY` / `FUNCTIONS_DEPLOYED`.
- Current Core WhatsApp migrations are present through the Aug-26 main migration set, including CORE-A/B/C and knowledge bridge.
- Required tables exist: `orders`, `sales_order_drafts`, `whatsapp_messages`, `whatsapp_message_packets`, `whatsapp_intelligence_knowledge_snapshots`.
- Before certification seeding: orders = 0, sales-order drafts = 0, WhatsApp messages = 0.
- Critical WhatsApp Edge Functions are deployed, including webhook, stitcher, operator reply, content interpretation, packet AI worker, Studio bridge and reconciliation worker.

## S0 security preflight

Supabase Advisor output was checked against actual grants and function bodies rather than treated as an automatic release blocker.

- `staff_provisionable_roles` has RLS disabled but no `anon` table grant; only `authenticated SELECT` and service/postgres authority are present. The table contains the static staff role catalogue and step-up flags. Track as platform hardening debt; it is not a WhatsApp certification authority bypass.
- Advisor warnings for `complete_notification_v1` and `fail_notification_v1` are constrained in-function to `auth.role() = service_role`.
- `resolve_dead_letter_v1` requires service role or authenticated admin/super-admin authority in-function.
- `recalculate_erp_order_financials` and the flagged WhatsApp autonomy guard helpers are trigger functions; the autonomy guards fail closed and are not usable as autonomous public mutation APIs.
- Critical WhatsApp commercial RPCs checked in this preflight are not executable by `anon`; they are authenticated/service paths with governed checks.

No S0 finding currently establishes a WhatsApp release blocker. Any platform-wide grant/RLS cleanup discovered here must be handled in a separate Core hardening PR and then re-certified; do not patch only the preview database.

## Deterministic staging smoke evidence

Only synthetic CERT namespace records were seeded; no production/customer data was copied.

1. **Clear employee-mediated order**
   - input: 12 boxes `BAK-PIST-250`, Taj Sweets Bengaluru / Main Store
   - result: `AUTO_ELIGIBLE`
   - readiness: all required dimensions resolved
   - draft execution: `PROMOTED`
   - exactly one sales-order draft and one promoted order
   - replay produced no duplicate order/draft/decision rows

2. **Missing quantity**
   - result: `CLARIFICATION_REQUIRED`
   - quantity remained unresolved
   - no autonomous draft execution
   - customer clarification was created

3. **Adversarial invented COD / 99% discount**
   - input interpretation contained `payment_terms=COD`, `unit_price=1`, `discount=99`
   - governed customer terms remained authoritative `credit`
   - governed line contained no AI `unit_price` or `discount`
   - exact SKU and quantity remained evidence-backed
   - autonomous commercial false-positive/invention leakage observed: 0

Current certification-window accounting after these smoke probes:
- raw inbound = 3
- packet fragments = 3
- orphan raw = 0
- packets without case = 0
- potential orders = 2
- autonomy decisions = 3
- sales-order drafts = 2
- promoted orders = 2

The two later same-sender probes intentionally exercised packet continuity; therefore case count is not expected to equal raw-message count in this smoke. Formal corpus scoring remains the CERT-A/protected-corpus scorer, not these manual smoke counts.

## Historical corpus status

Canonical protected source is the original Oasis B2B WhatsApp export kept outside Git. The raw media ZIP is too large for the Drive connector download limit. H1 parser work begins when the extracted WhatsApp `.txt` export is made available separately. Media remains linked later by WhatsApp-export filenames; do not upload or commit the full raw archive into this repository.

## Remaining gates

- H1/H2/H3 representative protected historical benchmark
- Cross-repository staging E2E
- Retry/concurrency/crash/reconciliation certification
- Normal + festival load profile
- Real non-production WhatsApp provider proof
- Final release certification ledger and GO/NO-GO

## Exit

After certification evidence is complete, close this PR and retire the preview branch unless it is deliberately retained for future certification.
