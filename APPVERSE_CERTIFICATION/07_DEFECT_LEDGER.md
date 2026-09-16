# Defect Ledger

Certification date: 2026-09-15

## CERT-WA-001 — Stitched inbound packets can remain without governed cases

- Severity: **P1 — HIGH / launch-blocking**
- State: **FAIL — zero-loss failover repaired in certification branch; durable AI-consumer repair still open**
- Environment: production read-only evidence + isolated Supabase preview repair verification
- Production evidence:
  - 168 unresolved `PACKET_WITHOUT_CASE` reconciliation rows
  - 152 distinct packets without communication cases
  - all 152 packets are open, `sender_identified=false`, `intent_classified=false`
  - linked messages are genuine inbound provider records (text/image/document)
  - 157 `whatsapp_packet_ai_dispatch_jobs` rows are `QUEUED`, all `attempt_count=0`, all retry-due
  - 152 queued PACKET jobs have no governed case; 5 queued jobs already have cases
- Root cause:
  1. current production packet-AI worker deployment is older than current Core source and lacks durable `claim_next` lease execution;
  2. the live/current Central stitcher invokes the AI worker directly by `packet_id`, bypassing the dispatch lease/complete/retry path;
  3. no independent scheduled consumer drains queued AI jobs;
  4. reconciliation reports missing cases but historically did not create a fail-closed human triage case.
- Safety impact: valid business evidence can remain outside the governed case/identity/intent workflow even though raw packets remain visible.
- Repair added:
  - migration `20260915110000_whatsapp_packet_case_failover.sql`
  - service-role-only `whatsapp_materialize_stale_packet_case_failover()`
  - hourly reconciliation wrapper now materializes stale packets into `UNCLASSIFIED / NEEDS_IDENTITY` Operations cases with explicit human review and no automatic commercial action.
  - failover leaves AI dispatch jobs queued so later governed enrichment remains possible.
- Regression:
  - `supabase/tests/20260915230000_whatsapp_packet_case_failover.sql`
  - preview transaction certification: PASS (`case_count=1`, `event_count=1`, `open_exception_count=0`, AI job remained `QUEUED`).
- Remaining action before closure:
  - repair and certify durable AI queue consumption;
  - exact-head CI/pgTAP PASS;
  - controlled production migration/deployment;
  - controlled backlog reconciliation proving no unaccounted inbound packets.

## CERT-SEC-001 — `staff_provisionable_roles` has RLS disabled

- Severity: **P2 — MEDIUM hardening**
- State: **OPEN**
- Production evidence: RLS disabled; table has 40 rows. `authenticated` has SELECT; anon has no table grant.
- Current risk: authenticated users can read the provisioning-role catalogue without RLS segmentation. This is not a demonstrated privilege escalation, but it violates the expected fail-closed data-layer posture.
- Required repair: determine whether this is intentionally public-to-staff metadata; either enable RLS with explicit staff/admin SELECT policy or move it behind a governed RPC/view.

## CERT-SEC-002 — Anonymous announcement counters are mutable without identity/idempotency controls

- Severity: **P2 — MEDIUM integrity**
- State: **OPEN**
- Evidence: anon can execute `increment_announcement_counter(uuid,text)`; function increments view/skip/completion counters for caller-supplied announcement IDs.
- Impact: analytics/engagement counters can be inflated or replayed anonymously.
- Required repair: bind to a public-safe idempotent event key/rate guard or route through a controlled endpoint.

## CERT-UI-001 — Historical AdminFinance modal/FAB layering defect

- Severity: historical P2
- State: **PASS — regression closed on current Central main**
- Current evidence: `AdminFinance.tsx` uses `z-[180]` backdrop and `z-[190]` modal/content tiers; repository z-index hierarchy documents these tiers.
- Action: retain as regression item; do not reopen the old patch.
