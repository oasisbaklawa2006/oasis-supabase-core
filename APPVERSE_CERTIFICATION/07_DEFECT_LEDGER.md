# App-Verse Certification Defect Ledger

Certification update: 2026-09-19

This is the canonical defect ledger for Core release authority. `CURRENT` records
describe live release posture; `SUPERSEDED` and `HISTORICAL` records are retained
only for traceability. A P0 or P1 `CURRENT` record with `Release gate = BLOCK`
must prevent a production migration release. The gate is enforced by
`scripts/check-defect-ledger.sh --enforce` in Production Migration Release.

<!-- RELEASE_GATE_INDEX:START -->
| Error ID | Severity | Classification | Repository / domain | Status | Code / runtime state | Production impact | Required next action | Certification / evidence reference | Release gate | Owner / routing | Exact evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T5-WA-001 | P1 | CURRENT | Core / WhatsApp operator-reply runtime | BLOCKED_EXTERNAL | CODED; TESTED; DEPLOYED; idle authenticated scheduler invocation RUNTIME_VERIFIED | Release authority blocked; no unsafe customer send was attempted | Use one safely eligible, authorised item to capture provider acceptance, then delivery and alert closure | 2026-09-19 pg_net request `6701`; Core PR #337 | BLOCK | Core WhatsApp owner; Mission Control release authority | Core `d6c6a662703c04f90f7e79c790d3b994f9a61f1b`; function `whatsapp-operator-reply-consumer` v1, `verify_jwt=false`; disable-to-missing-URL-to-restore recovery proven; no eligible row or provider acknowledgement existed |
| T5-AI-001 | P2 | CURRENT | AI Studio / reconciliation artefact deployment manifest | OPEN | Reconciliation artefact remains source-controlled; no Task 5 runtime remediation claimed | P2 only; no current Core P1 release impact asserted | Dedicated AI Studio task must align the declared deployment manifest and evidence | Task 5 evidence packet 2026-09-19 | TRACK | AI Studio owner / App-Verse Task 1 | `appverse_reconciliation_artifact_log` is absent from the declared AI Studio deployment manifest |
| CERT-SEC-001 | P2 | CURRENT | Core / database access control | OPEN | Security hardening not remediated | Authenticated provisioning-role catalogue visibility remains insufficiently segmented | Confirm intended model and add governed RLS policy or RPC/view in a forward Core migration | Core certification evidence 2026-09-15 | TRACK | Core security owner | `staff_provisionable_roles` RLS disabled; 40 rows; authenticated SELECT grant observed during certification |
| CERT-SEC-002 | P2 | CURRENT | Core / anonymous analytics integrity | OPEN | Integrity hardening not remediated | Announcement counters can be replayed or inflated anonymously | Add public-safe idempotency and rate governance in a forward Core change | Core certification evidence 2026-09-15 | TRACK | Core security owner | anonymous `increment_announcement_counter(uuid,text)` remains mutable without identity or idempotency control |
| T5-AI-002 | P2 | CURRENT | Core and Supabase runtime / product attributes | BLOCKED_EXTERNAL | Canonical Core source has a retirement tombstone; separately deployed runtime function remains active outside this Core release scope | Retired function remains visible in runtime inventory; no uncontrolled authoritative write was evidenced | Execute a dedicated rollback-planned retirement or replacement with its owning runtime team | Task 5 production function inventory 2026-09-19 | TRACK | Supabase runtime owner / AI Studio owner | Core `generate-product-attributes` returns governed retirement response; production inventory still reported active `generate-product-attributes` v129 |
| CERT-WA-001 | P1 | SUPERSEDED | Core / historical packet-case repair | SUPERSEDED | Superseded by the durable outbox-consumer implementation and Task 5 runtime evidence | No current code defect counted | Keep historical evidence only; route any runtime certification through T5-WA-001 | Core repairs #328, #334, #336 | ALLOW | Core WhatsApp owner | Historical 2026-09-15 finding; Task 5 tracking continues as T5-WA-001 |
| CERT-UI-001 | P2 | HISTORICAL | Central / AdminFinance layering | CLOSED | Regression closed on current Central main | No current release impact | Retain as regression history; do not reopen the old patch | Current Central main evidence 2026-09-19 | ALLOW | Central owner | `AdminFinance.tsx` uses documented `z-[180]` backdrop and `z-[190]` modal tiers |
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

### T5-AI-001, CERT-SEC-001, CERT-SEC-002, and T5-AI-002

These are retained as current P2 routing records. They are not silently treated
as Core runtime closure, and their owners must supply independent implementation
and verification evidence before their states advance.

## Historical detail retained for CERT-WA-001

The 2026-09-15 certification identified packets without governed cases and a
missing durable AI consumer. Its failover repair and preview regression evidence
remain historically useful, but it is no longer the current release record.
Task 5 runtime closure is tracked only by `T5-WA-001` above.
