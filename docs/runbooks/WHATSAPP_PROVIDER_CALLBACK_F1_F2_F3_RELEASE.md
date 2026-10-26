# WhatsApp F1/F2/F3 — governed provider-callback repair and production certification

## Scope and authority

This runbook accompanies Core PR #461 and WA FINAL issue #450. It does not authorize a production release, provider sends, bypass of AAL2, or broad WhatsApp launch. Merging a PR is not deployment or live certification.

Verified pre-merge Core main: `3680cdaf8b931e12e4f47744304c90210de54e6b`.
Before any release, resolve the **actual squash-merged SHA from current main**, not the old PR head.

Only the signed, approved production migration workflow may apply `20261026170000_whatsapp_provider_callback_failed_batch.sql`. The already-reviewed named-function production webhook release lane must deploy the exact reviewed `whatsapp-webhook` source **after** that migration passes its independent production schema verification.

### Intended changed behavior

- Authenticated Meta status callbacks are flattened across all `entry[].changes[].value.statuses[]`; callback event identities are not inferred from senders or queue IDs.
- Recognized statuses `sent/accepted/delivered/read/failed/undelivered` use the service-only atomic `persist_whatsapp_operator_reply_provider_status` RPC with a bounded event audit. `failed` and `undelivered` map to the outbox's existing terminal `FAILED_FINAL` state and bounded/sanitized error code.
- `DELIVERED` and `READ` may not be overwritten by a delayed failure; `FAILED_FINAL` cannot be resurrected by a stale positive callback.
- A batch continues processing later recognized statuses even if an earlier member fails; only after processing all members will the webhook return 503 so legitimate transient callback delivery can retry. Duplicate callbacks are idempotent.
- Advisory provider statuses such as `warning` and `deleted` do not enter the delivery-state ladder and do not cause an endless retry.
- Direct `Click2API POST /messages` from `whatsapp-webhook` is forbidden. The formerly reachable ledger-dispute auto-acknowledgement is suppressed; governed Core-C outbound messaging must be evidenced separately. The legacy `sendReply` helper throws if its dormant code path becomes reachable.
- Webhook and dependent company resolver/Studio Inbox use a single pinned npm Supabase client type; the security CI includes the actual webhook entrypoint.

## Mandatory release sequence

1. Independently approve the PR on the exact final head, check CodeRabbit and all required green checks including pgTAP, preview Edge bundle and Core Merge Governance; squash-merge through protected main only. Do not bypass failed external checks.
2. Confirm the protected production target is project `tcxvcatsqqertcnycuop`, record production `whatsapp-webhook` version/bundle metadata, capture reversible source provenance, SQL function definition and provider-ID constraint, and record independent pre-release outbox aggregate counters without customer identifiers.
3. Through **Production Migration Release** only, dispatch approved `deploy=true` at the exact merged main SHA, under `supabase-production` environment approval. Apply only the reviewed forward migration. A green CI replay or preview migration does **not** apply production SQL.
4. Independently read the production migration ledger and deployed RPC contract: `FAILED_FINAL` permitted for provider-linked rows; `anon` and `authenticated` EXECUTE denied; `service_role` permitted; atomic lock, bounded error evidence, no-delivery-regression and immutable event trigger present.
5. Through the approved **WhatsApp Webhook Production Release** lane, release only the exact-source `whatsapp-webhook` named Edge function at reviewed source SHA, with rollback capture and version/bundle attestation. Do not use raw `deploy_edge_function` to skip governance.
6. Confirm the webhook's authenticated challenge/signature boundary before forwarding any provider status, then verify successful Edge health, no new 5xx ingress, bounded/idempotent retries and the exact deployed bundle.
7. In an isolated provider sandbox or through a **dedicated consenting test recipient**, execute two different message IDs in one signed callback; repeated delivered/read, delayed failure, failure code, early unmatched then matched, and acceptance-unknown retry. Record synthetic/consented provider IDs as redacted hashes, count each unique callback, verify durable one-to-one outbox status/audit lineage, verify **zero unauthorized sends**.
8. Confirm separate signed-in Support/Admin staff workflow with enrolled AAL2, approved SKU/MOQ fixture, and shift-level zero-loss reconciliation signoff before claiming the *whole WhatsApp module* production-certified.

## Fail-closed limitations and disposition

- **Mixed Meta inbound messages + status events**: status members are persisted idempotently but the webhook returns HTTP 503 rather than acknowledge unprocessed inbound members. This is **not** a fully certified mixed-payload acceptance path. Provider compatibility and bounded replay behavior require explicit provider UAT and/or a separate reviewed handler; do not claim zero-loss for mixed batches based on this PR alone.
- **Click2API payload format**: the observed `message.message_status` plus `response.messages[0].id` callback shape comes from existing synthetic tests; validate against actual provider sandbox before concluding customer receipts are fixed.
- **Historical 69 ACCEPTED / 70 QUARANTINED** reply states, 1 oversized DEAD_LETTER dispatch job, unowned staff backlog, dormant MFA and non-ready orders are outside this automatic repair. Do not replay or mass-close to manufacture green counters.
- **Migration reversal**: the provider-ID CHECK and function definition can be restored only through a separately reviewed forward-compensating migration after confirming no `FAILED_FINAL` provider-linked records would be invalidated; retain exact pre-release definition evidence. Rollback the Edge function by approved protected workflow to its captured version only after considering DB compatibility.
- **Preview infra issue on 2026-10-26**: hosted Supabase branch `surosmqmgylfrugjpilv` reported Edge bundling failure in unrelated `generate-bi-monthly-ledger/index.ts`, caused by `https://esm.sh/pdf-lib@1.17.1` returning HTTP 521. Do **not** modify the unrelated finance function as part of the WhatsApp review; retry preview or route the infrastructure issue to its owner. All mandatory checks must be green before owner merge.

## Evidence

- GitHub issue #450: final WhatsApp certification ledger, executed UAT batches, provider/staff/identity blockers.
- PR #461: code review, CodeRabbit disposition, per-head CI and this runbook.
- Supabase preview: migration `20261026170000` verified in the existing preview project; the official GitHub **Clean database replay and pgTAP contracts** workflow is authoritative for executable SQL tests.
- Production webhook remains on the prior version until a separately approved release; never confuse PR merge, production SQL application, Edge deployment and consented callback verification.
