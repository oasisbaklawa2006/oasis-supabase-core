# WA-7 WhatsApp software release certification

This matrix certifies the reviewed software path only. It does not deploy migrations, edge functions, secrets, or provider configuration. A controlled pilot remains **NO-GO** until the live-number procedure below passes in staging.

## Automated evidence matrix

| Release path / hostile condition | Executable evidence | Required result |
|---|---|---|
| Authenticated ingress, duplicate webhook, provider retry | WA-1 and WA-4 pgTAP; Central ingress governance test | one durable potential order; no client mutation path |
| Fragmented, out-of-order, late and corrected messages | `20260813180000_wa4_multimessage_multimodal.sql` | deterministic lineage; no cross-contact stitching |
| Image, PDF, multiple, corrupt, unsupported and timed-out media | WA-4 pgTAP | original evidence retained; failure remains actionable |
| AI failure, low confidence, missing/contradictory product, quantity, unit, address or terms | WA-3 hostile pgTAP | clarification work; no invented fact; promotion blocked |
| Duplicate clarification response | WA-3 hostile pgTAP | one evidence/resolution transition |
| Unauthorized, inactive or Support operator | WA-2, WA-3 and WA-6 pgTAP | mutation/promotion/disclosure denied |
| Recipient mismatch and cross-customer disclosure | WA-5 and WA-6 pgTAP | enqueue rejected before provider work exists |
| Outbound timeout/retry and duplicate reply | WA-5 pgTAP | `ACCEPTANCE_UNKNOWN`; retry suppressed; callback reconciliation |
| Pricing, MOQ, terms, address, history, balance, draft/SO disclosure | WA-6 pgTAP | verified company/contact plus time-bounded AAL2 scope required |
| Concurrent/duplicate promotion | WA-3 blocker and WA-7 aggregate pgTAP | row lock + idempotent already-promoted result; one SO |
| Whole-chain invariants | `20260813210000_wa7_whatsapp_release_certification.sql` | immutable lineage and `unaccounted_potential_orders = 0` |
| Central integration | Release Quality Gate | typecheck, changed-file lint, full Vitest, production build, Playwright smoke |

## Staging secrets and configuration

Configure these only in the staging edge-function secret store; never in browser bundles, logs, PRs, or test artifacts:

- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`
- `CLICK2API_API_KEY` and, when required by the provider account, `CLICK2API_ACCESS_TOKEN`
- a new high-entropy `WHATSAPP_WEBHOOK_VERIFY_TOKEN`
- a distinct high-entropy `WHATSAPP_WEBHOOK_SECRET`, configured in Click2API to arrive as `x-webhook-secret` (or its supported `x-click2api-signature` header)
- `LOVABLE_API_KEY` only if staging extraction is enabled; absence must exercise fail-open-to-human handling
- `B2B_PORTAL_URL` set to the staging portal
- `ENABLE_WA_WEBHOOK_AUTO_ORDER_WRITES=false` and `ENABLE_WA_WEBHOOK_OWNER_REASSIGNMENT=false`

## Live-number certification procedure

1. Deploy the exact merged Core/Central release candidates to an isolated staging project through the normal approval-controlled release process. Do not use production data or numbers.
2. Confirm an invalid handshake token returns 403, a valid token returns only the provider challenge, a missing/invalid POST secret returns 401, and secrets/payloads do not appear in logs.
3. From customer A, send: fragmented text with an ambiguous abbreviation and missing unit, an unreadable image, then “not 10 boxes, make it 12 cartons”; forward the correction once. Send an unrelated order concurrently from customer B.
4. Disable the extraction key or force extraction failure. Verify exactly one customer-A potential order survives with every provider message/attachment, failed interpretation/media work is visible, customer B is isolated, and reconciliation reports zero unaccounted.
5. Have Support attempt correction, disclosure and promotion; all prohibited actions must fail. Have an authorized operator answer only the outstanding clarification and verify the original candidates remain immutable.
6. Attempt pricing/history disclosure before recipient authorization; it must fail. Grant the minimum staging scope with an AAL2 admin, confirm the intended recipient, then send one governed clarification/template.
7. Force a provider timeout after acceptance. Retry the same UI action and verify no duplicate customer message; reconcile the provider callback through ACCEPTED/DELIVERED/READ.
8. Resolve every mandatory dimension, promote with AAL2, then concurrently repeat promotion. Verify one Sales Order, one set of items, an already-promoted response, complete audit lineage, and `unaccounted_potential_orders = 0`.
9. Revoke the disclosure authorization and deactivate the operator; subsequent send/promotion attempts must fail.
10. Preserve redacted screenshots, provider IDs, database query results, CI URLs and exact deployed SHAs as the signed pilot evidence pack.

Pilot recommendation before this procedure: **NO-GO (live certification outstanding)**. If every step passes on the exact release SHAs with no unresolved review/security finding: **GO for a limited, monitored staging-to-pilot release through the existing production approval gate**.
