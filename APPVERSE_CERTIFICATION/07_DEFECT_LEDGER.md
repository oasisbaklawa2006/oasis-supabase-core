# App-Verse Certification Defect Ledger

Certification update: 2026-09-27

This is the canonical defect ledger for Core release authority. `CURRENT` records
describe live release posture; `SUPERSEDED` and `HISTORICAL` records are retained
only for traceability. A P0 or P1 `CURRENT` record with `Release gate = BLOCK`
must prevent a production migration release. The gate is enforced by
`scripts/check-defect-ledger.sh --enforce` in Production Migration Release.

<!-- RELEASE_GATE_INDEX:START -->
| Error ID | Severity | Classification | Repository / domain | Status | Code / runtime state | Production impact | Required next action | Certification / evidence reference | Covered Core revision | Provider acceptance identifier | Delivery evidence | Alert / reconciliation closure evidence | Release gate | Owner / routing | Exact evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T5-WA-001 | P1 | CURRENT | Core / WhatsApp operator-reply runtime | RUNTIME_VERIFIED | CODED; TESTED; DEPLOYED; provider acceptance + sent/delivered/read + fail-safe reconciliation RUNTIME_VERIFIED | Release authority unblocked by production provider evidence; forward #348 atomic status persistence still requires governed production deployment | Retain runtime evidence and deploy the #348 forward migration + named `whatsapp-webhook` release through protected production gates | `APPVERSE_CERTIFICATION/09_T5_WA_RUNTIME_CLOSURE_20260927.md`; 2026-09-19 pg_net request `6701`; Core PR #337 | `d6c6a662703c04f90f7e79c790d3b994f9a61f1b` | `8817da5f-218d-4e00-b0f3-5cf33db06922` | Meta `wamid.HBgMOTE5OTcxNzc3MDA2FQIAERgSNTQzQzcxQTFGRkQ3QTI2NERDAA==`; delivered webhook `57dbcea2-120d-46e4-8bc1-addc2d447ea3`; read webhook `ae4fea81-9d62-4d60-8fd7-a631964650b8` | acceptance-unknown reply `1de36ceb-ebc0-4406-84ae-ba1ef47387e7` reconciled to `QUARANTINED` / `DO_NOT_SEND` at 2026-09-27 12:13:14+00 | ALLOW | Core WhatsApp owner; Mission Control release authority | production consumer v1 active; scheduler active; accepted autonomous reply at 06:02:01+00 correlated read-only to same-recipient Meta sent→delivered→read callbacks within 10s; no synthetic send used |
| T5-AI-001 | P2 | HISTORICAL | AI Studio / reconciliation artefact deployment manifest | CLOSED | Repository + production census found no implemented/runtime artefact and no machine deployment manifest declaring one | No current production impact; prior row described a non-existent deployable object | Retain historical evidence only; do not create a runtime object merely to satisfy stale certification prose | Task 5 non-hardware seal 2026-09-21 | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | ALLOW | AI Studio owner / App-Verse Task 1 | `appverse_reconciliation_artifact_log` appears only in certification prose; production `to_regclass(...)` = NULL |
| CERT-SEC-001 | P2 | HISTORICAL | Core / database access control | CLOSED | DEPLOYED; production read-only verification confirms RLS enabled, authenticated access revoked and explicit deny policy present | No current production impact | Retain as regression evidence; no further mutation required | Migration `20260915210000_supabase_advisor_security_hardening` + Task 5 non-hardware seal 2026-09-21 | `671781475ef8a625afec96c5336158a504c5e287` | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | ALLOW | Core security owner | production: `relrowsecurity=true`; ACL owner/service_role only; `staff_provisionable_roles_authenticated_deny USING(false)` |
| CERT-SEC-002 | P2 | CURRENT | Core / announcement analytics integrity | BLOCKED_EXTERNAL | SOURCE_FIX_INCLUDED; authenticated idempotent receipt contract added; production apply held by canonical Task 5 P1 release gate | Production legacy RPC remains replayable until governed release is permitted | After T5-WA-001 release clearance, apply the forward migration through Protected Production Migration Release and verify privileges/idempotency read-only | Task 5 non-hardware seal 2026-09-21 | PENDING_MERGE | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | TRACK | Core security owner / Mission Control release authority | forward migration denies PUBLIC/anon, preserves authenticated RPC shape and deduplicates actor+announcement+counter |
| T5-AI-002 | P2 | HISTORICAL | Core and Supabase runtime / product attributes | CLOSED | DEPLOYED_SOURCE_VERIFIED; production v129 source is already a 410 retirement tombstone and Core main source is likewise retired | No active legacy product-attribute generation authority evidenced | Retain as regression history; ACTIVE function inventory state alone does not mean legacy business behavior is active | Task 5 non-hardware seal 2026-09-21 | `671781475ef8a625afec96c5336158a504c5e287` | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | ALLOW | Supabase runtime owner / AI Studio owner | deployed v129 returns `error: endpoint_retired`, replacement `catalogue-ai-copy`; Core source returns HTTP 410 |
| CERT-WA-001 | P1 | SUPERSEDED | Core / historical packet-case repair | SUPERSEDED | Superseded by the durable outbox-consumer implementation and Task 5 runtime evidence | No current code defect counted | Keep historical evidence only; route any runtime certification through T5-WA-001 | Core repairs #328, #334, #336 | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | ALLOW | Core WhatsApp owner | Historical 2026-09-15 finding; Task 5 tracking continues as T5-WA-001 |
| CERT-UI-001 | P2 | HISTORICAL | Central / AdminFinance layering | CLOSED | Regression closed on current Central main | No current release impact | Retain as regression history; do not reopen the old patch | Current Central main evidence 2026-09-19 | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | NOT_APPLICABLE | ALLOW | Central owner | `AdminFinance.tsx` uses documented `z-[180]` backdrop and `z-[190]` modal tiers |
<!-- RELEASE_GATE_INDEX:END -->

## Current release decision

`T5-WA-001` no longer blocks release authority. Read-only production evidence
captured on 2026-09-27 found a naturally occurring autonomous outbox item with
a real Click2API acceptance identifier, followed within seconds by the matching
same-recipient Meta `sent`, `delivered`, and `read` callback chain. The prior
acceptance-unknown path is also reconciled fail-safe to `QUARANTINED` /
`DO_NOT_SEND`.

No synthetic message or production mutation was performed to manufacture this
evidence. The detailed evidence is preserved in
`APPVERSE_CERTIFICATION/09_T5_WA_RUNTIME_CLOSURE_20260927.md`.

This clears the Task 5 P1 runtime release gate only. It does not claim the #348
atomic callback-persistence forward change is already live; that migration and
the named `whatsapp-webhook` release remain governed production deployment work.

## Record notes and routing

### T5-WA-001 — durable operator-reply outbox consumer

- Severity: **P1**
- Current status: **RUNTIME_VERIFIED**
- Code state: **CODED, TESTED, DEPLOYED**
- Runtime state: **provider acceptance plus same-recipient sent/delivered/read
  callbacks verified from production evidence**
- Reconciliation state: prior acceptance-unknown case is **QUARANTINED /
  DO_NOT_SEND**; no blind replay remains required for this certification row.
- Release gate: **ALLOW**. Forward #348 persistence still follows protected
  production migration and named Edge deployment governance.

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
