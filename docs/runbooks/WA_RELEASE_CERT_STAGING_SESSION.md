# WhatsApp Release Certification — Isolated Staging Session

This branch exists only to provision and certify an isolated Supabase preview environment for the WhatsApp release-certification programme.

## Authority

- Canonical Core base: `f8a850c39e5662d9ada5d16c30682d4ae2e2f516`
- Certification branch: `cert/wa-release-cert`
- Certification PR: `#126`
- Isolated Supabase preview project: `dfjslkwxawnzurolifpm`
- Production project: `tcxvcatsqqertcnycuop`
- Preview is `with_data=false`; production data is not copied.
- Production must remain untouched.

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
