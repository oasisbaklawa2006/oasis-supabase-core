# App-Verse Certification Defect Ledger

Certification update: 2026-09-19

This is the canonical defect ledger for Core release authority. `CURRENT` records
describe live release posture; `SUPERSEDED` and `HISTORICAL` records are retained
only for traceability. A P0 or P1 `CURRENT` record with `Release gate = BLOCK`
must prevent a production migration release. The gate is enforced by
`scripts/check-defect-ledger.sh --enforce` in Production Migration Release.

<!-- RELEASE_GATE_INDEX:START -->
| Error ID | Severity | Classification | Repository / domain | Status | Code / runtime state | Production impact | Required next action | Certification / evidence reference | Covered Core revision | Provider acceptance identifier | Delivery evidence | Alert / reconciliation closure evidence | Release gate | Owner / routing | Exact evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T5-WA-001 | P1 | CURRENT | Core / WhatsApp operator-reply runtime | BLOCKED_EXTERNAL | CODED; TESTED; DEPLOYED; idle authenticated scheduler invocation RUNTIME_VERIFIED | Release authority blocked; no unsafe customer send was attempted | Use one safely eligible, authorised item to capture provider acceptance, then delivery and alert closure | 2026-09-19 pg_net request `6701`; Core PR #337 | `d6c6a662703c04f90f7e79c790d3b994f9a61f1b` | PENDING_EXTERNAL | PENDING_EXTERNAL | PENDING_EXTERNAL | BLOCK | Core WhatsApp owner; Mission Control release authority | function `whatsapp-operator-reply-consumer` v1, `verify_jwt=false`; disable-to-missing-URL-to-restore recovery proven; no eligible row or provider acknowledgement existed |
| T5-AI-001 | P2 | HISTORICAL | AI Studio / reconciliation artefact deployment manifest | CLOSED | Repository + production census found no implemented/runtime artefact and no machine deployment manifest declaring one | No current production impact; prior row described a non-existent deployable object | Retain historical evidence only; do not create a runtime object merely to satisfy stale certification prose | Task 5 non-hardware seal 2026-09-21 | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | ALLOW | AI Studio owner / App-Verse Task 1 | `appverse_reconciliation_artifact_log` appears only in certification prose; production `to_regclass(...)` = NULL |
| CERT-SEC-001 | P2 | HISTORICAL | Core / database access control | CLOSED | DEPLOYED; production read-only verification confirms RLS enabled, authenticated access revoked and explicit deny policy present | No current production impact | Retain as regression evidence; no further mutation required | Migration `20260915210000_supabase_advisor_security_hardening` + Task 5 non-hardware seal 2026-09-21 | `671781475ef8a625afec96c5336158a504c5e287` | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | ALLOW | Core security owner | production: `relrowsecurity=true`; ACL owner/service_role only; `staff_provisionable_roles_authenticated_deny USING(false)` |
| CERT-SEC-002 | P2 | CURRENT | Core / announcement analytics integrity | BLOCKED_EXTERNAL | SOURCE_FIX_INCLUDED; authenticated idempotent receipt contract added; production apply held by canonical Task 5 P1 release gate | Production legacy RPC remains replayable until governed release is permitted | After T5-WA-001 release clearance, apply the forward migration through Protected Production Migration Release and verify privileges/idempotency read-only | Task 5 non-hardware seal 2026-09-21 | PENDING_MERGE | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | TRACK | Core security owner / Mission Control release authority | forward migration denies PUBLIC/anon, preserves authenticated RPC shape and deduplicates actor+announcement+counter |
| T5-AI-002 | P2 | HISTORICAL | Core and Supabase runtime / product attributes | CLOSED | DEPLOYED_SOURCE_VERIFIED; production v129 source is already a 410 retirement tombstone and Core main source is likewise retired | No active legacy product-attribute generation authority evidenced | Retain as regression history; ACTIVE function inventory state alone does not mean legacy business behavior is active | Task 5 non-hardware seal 2026-09-21 | `671781475ef8a625afec96c5336158a504c5e287` | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | ALLOW | Supabase runtime owner / AI Studio owner | deployed v129 returns `error: endpoint_retired`, replacement `catalogue-ai-copy`; Core source returns HTTP 410 |
| CERT-WA-001 | P1 | SUPERSEDED | Core / historical packet-case repair | SUPERSEDED | Superseded by the durable outbox-consumer implementation and Task 5 runtime evidence | No current code defect counted | Keep historical evidence only; route any runtime certification through T5-WA-001 | Core repairs #328, #334, #336 | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | ALLOW | Core WhatsApp owner | Historical 2026-09-15 finding; Task 5 tracking continues as T5-WA-001 |
| CERT-UI-001 | P2 | HISTORICAL | Central / AdminFinance layering | CLOSED | Regression closed on current Central main | No current release impact | Retain as regression history; do not reopen the old patch | Current Central main evidence 2026-09-19 | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | ALLOW | Central owner | `AdminFinance.tsx` uses documented `z-[180]` backdrop and `z-[190]` modal tiers |
<!-- RELEASE_GATE_INDEX:END -->

## Current release decision

`T5-WA-001` is the only P0/P1 release blocker in the current ledger. It is not
closed because no safely eligible production outbox item existed from which to
obtain a real provider acceptance identifier. The completed runtime evidence is
therefore deliberately narrower than a delivery claim:

- the function was deployed from the current Core source, preserving
  `verify_jwt=false` for its custom machine-secret contract;
- the scheduler URL Vault record was activated and a controlled scheduler tick
  yielded pg_net request `6701` with HTTP 200;
- no outbox row changed, no active lease or acceptance-unknown state was
  created, and no customer message was sent because no row was eligible;
- fail-closed recovery was proved by removing the URL value (tick returned
  `consumer_url_missing`) and restoring the governed URL; and
- provider acceptance, delivery evidence, and alert-closure evidence remain
  required before changing this record to `RUNTIME_VERIFIED` or `CLOSED`.

## Record notes and routing

### T5-WA-001 — durable operator-reply outbox consumer

- Severity: **P1**
- Current status: **BLOCKED_EXTERNAL**
- Code state: **CODED, TESTED, DEPLOYED**
- Runtime state: **authenticated idle-path invocation verified; no provider send
  asserted**
- Remaining gate: a controlled, authorised, non-customer or explicitly approved
  production item must produce a provider acceptance identifier, followed by
  delivery/alert closure evidence. Do not manufacture a message merely to close
  this record.

### P2 reconciliation — 2026-09-21

Read-only production and repository census closed three stale P2 rows without
manufacturing runtime objects or performing a production mutation:

- T5-AI-001 is historical/closed because no implementation, runtime relation or
  machine deployment-manifest object exists to reconcile.
- CERT-SEC-001 is historical/closed because the previously deployed
  `20260915210000_supabase_advisor_security_hardening` migration is present
  live and RLS/ACL/policy checks now prove the finding is remediated.
- T5-AI-002 is historical/closed because the deployed v129 function source is
  already the 410 retirement tombstone; an ACTIVE inventory record is only the
  deployment object's lifecycle state.
- CERT-SEC-002 remains current until its forward hardening migration is deployed
  after the canonical P1 release gate clears. Source/test completion alone is
  not represented as production closure.

## Historical detail retained for CERT-WA-001

The 2026-09-15 certification identified packets without governed cases and a
missing durable AI consumer. Its failover repair and preview regression evidence
remain historically useful, but it is no longer the current release record.
Task 5 runtime closure is tracked only by `T5-WA-001` above.
