# Task 5 non-hardware security / ledger seal — 2026-09-21

This record captures read-only production evidence used to reconcile stale
Task 5 P2 rows. It does **not** clear the provider-dependent P1 WhatsApp gate and
does not authorize any production mutation.

## CERT-SEC-001 — staff provisioning allowlist

Production project `tcxvcatsqqertcnycuop` was inspected read-only.

Observed:

- `public.staff_provisionable_roles.relrowsecurity = true`;
- table ACL exposes the relation only to the owner and `service_role`;
- authenticated direct SELECT is revoked;
- policy `staff_provisionable_roles_authenticated_deny` exists with
  `USING (false)`;
- migration `20260915210000_supabase_advisor_security_hardening` is recorded
  in production migration history.

Conclusion: the prior ledger text saying RLS was disabled / authenticated
SELECT remained available is stale. No new production mutation is required.

## T5-AI-002 — generate-product-attributes retirement

Read-only function inventory still lists a deployed Edge Function record named
`generate-product-attributes` (v129), but inspection of the deployed source
shows the endpoint is already a retirement tombstone: ordinary requests return
HTTP 410 with `error: "endpoint_retired"` and replacement
`catalogue-ai-copy`.

Core current-main source is also a 410 retirement tombstone. An ACTIVE
deployment-list status therefore describes the presence of the deployed
function object, not active legacy product-generation authority.

Conclusion: no legacy product-attribute mutation path was evidenced. The prior
ledger wording conflated deployed-object presence with active business
authority.

## T5-AI-001 — reconciliation artefact manifest row

Repository census across AI Studio, Central and Core found
`appverse_reconciliation_artifact_log` only in certification prose/ledger
references and no implementation/deployment object. Read-only production SQL
also resolves `to_regclass('public.appverse_reconciliation_artifact_log')`
to NULL. AI Studio has no machine deployment manifest declaring this runtime
object.

Conclusion: there is no runtime artefact to reconcile. Preserve the historical
finding, but it is not a current deployable defect.

## CERT-SEC-002 — announcement counters

Read-only production inspection confirmed
`increment_announcement_counter(uuid,text)` is a SECURITY DEFINER function
currently executable by PUBLIC/anon/authenticated and increments counters
without identity or idempotency.

The forward migration in this change:
- denies anonymous/PUBLIC execution;
- preserves the existing two-argument RPC shape for authenticated clients;
- records a server-owned receipt keyed by authenticated actor + announcement +
  counter type;
- makes exact replays no-ops;
- denies direct browser access to receipt rows;
- keeps service-role authority for governed server operations.

Production application remains subject to the canonical Task 5 release gate.
