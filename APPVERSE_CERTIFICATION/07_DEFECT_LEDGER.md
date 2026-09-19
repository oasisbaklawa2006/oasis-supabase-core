# App-Verse Certification Defect Ledger

Certification update: 2026-09-19

This is the canonical defect ledger for Core release authority. `CURRENT` records
describe live release posture; `SUPERSEDED` and `HISTORICAL` records are retained
only for traceability. A P0 or P1 `CURRENT` record with `Release gate = BLOCK`
must prevent a production migration release. The gate is enforced by
`scripts/check-defect-ledger.sh --enforce` in Production Migration Release.

<!-- RELEASE_GATE_INDEX:START -->
| Error ID | Severity | Classification | Status | Code / runtime state | Release gate | Owner / routing | Exact evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T5-WA-001 | P1 | CURRENT | BLOCKED_EXTERNAL | CODED; TESTED; DEPLOYED; RUNTIME_VERIFIED for an idle, authenticated scheduler invocation | BLOCK | Core WhatsApp owner; Mission Control release authority | Core `d6c6a662703c04f90f7e79c790d3b994f9a61f1b`; function `whatsapp-operator-reply-consumer` v1, `verify_jwt=false`; controlled pg_net request `6701` HTTP 200; disable-to-missing-URL-to-restore recovery proven; no eligible row or provider acknowledgement existed |
| T5-AI-001 | P2 | CURRENT | OPEN | Reconciliation artefact remains source-controlled; no Task 5 runtime remediation claimed | TRACK | AI Studio owner / App-Verse Task 1 | `appverse_reconciliation_artifact_log` is absent from the declared AI Studio deployment manifest |
| CERT-SEC-001 | P2 | CURRENT | OPEN | Security hardening not remediated | TRACK | Core security owner | `staff_provisionable_roles` RLS disabled; 40 rows; authenticated SELECT grant observed during certification |
| CERT-SEC-002 | P2 | CURRENT | OPEN | Integrity hardening not remediated | TRACK | Core security owner | anonymous `increment_announcement_counter(uuid,text)` remains mutable without identity or idempotency control |
| T5-AI-002 | P2 | CURRENT | BLOCKED_EXTERNAL | Canonical Core source has a retirement tombstone; separately deployed runtime function remains active outside this Core release scope | TRACK | Supabase runtime owner / AI Studio owner | Core `generate-product-attributes` returns governed retirement response; production inventory still reported active `generate-product-attributes` v129 |
| CERT-WA-001 | P1 | SUPERSEDED | SUPERSEDED | Superseded by the durable outbox-consumer implementation and Task 5 runtime evidence | ALLOW | Core WhatsApp owner | Historical 2026-09-15 finding; later Core repairs #328, #334, and #336; Task 5 tracking continues as T5-WA-001 |
| CERT-UI-001 | P2 | HISTORICAL | CLOSED | Regression closed on current Central main | ALLOW | Central owner | `AdminFinance.tsx` uses documented `z-[180]` backdrop and `z-[190]` modal tiers |
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
