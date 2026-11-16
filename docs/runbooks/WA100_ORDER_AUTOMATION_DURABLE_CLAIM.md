# WA-100 Order WhatsApp automation — protected durable single-claim candidate

**Not deployed.** Live `send-whatsapp-automation` v60 is a service-role-only Edge Function that delegates to the old `send-whatsapp` route. The live source attempts to insert `contact_id=null` into a NOT NULL `whatsapp_automations.contact_id` column. Production ledger contains no automation receipts. Sending occurs before receipt insertion, leaving it replay-prone.

## Source and database contract
- Core migration `20261116150000` adds unique `(order_id,trigger_type)` and service-role-only `claim_legacy_whatsapp_automation_v1(uuid,text,text,text)`. It creates/finds `whatsapp_contacts` by normalized phone inside the same SQL transaction, records a pending receipt and returns `claimed:true/false`.
- Candidate worker claims before calling any sender. `claimed:false` always suppresses sending, including prior failed, pending and acceptance-unknown events. No automatic retries or cross-provider fallback in this worker.
- It resolves the internal sender endpoint from the actual `SUPABASE_URL` rather than a development localhost fallback.
- Provider `success:true` is stored as `sent`, network uncertainty as `acceptance_unknown`, explicit rejection as `failed_final`; no fabricated delivered/read.
- A failure to finalize the receipt does **not** trigger another send. Staff must reconcile pending receipt by provider ID and decision logs.
- Exact 4 legacy triggers retained: `so_created`, `payment_verified`, `production_started`, `order_dispatched`.
- No credential changes, production migration or live messages made in this candidate.

## Dependencies
1. Owner confirms all four triggers' business copy, eligibility, marketing consent/Meta template requirements and order authority. Ordering event deduplication permits exactly one notification for each `(order_id,trigger_type)`; repeated deliberate reminders need a **separate versioned trigger**, not a bypass.
2. Independently approved production migration through Core protected release with pgTAP and runtime RLS/unique-index verification; no direct SQL DDL. Check prior schema migration #544 first.
3. Independently approved and deployed Core single-attempt legacy sender from #546; the old v143 source would still retry/fail over even if this worker is idempotent.
4. New protected *named-function* automation deploy workflow to be separately reviewed, requiring exact Core main SHA, pinned live v60 bundle and source closure backup, explicit production approval, post-deploy source readback.
5. Test duplicate invocation under concurrency against a clean/isolated database, real representative order, revoked roles, provider errors, network ambiguity, and the fully authenticated 1-message consented flow.
6. Do not retry past `FAILED_FINAL`, `QUARANTINED`, unknown-acceptance, or order events without an explicit owner reconciliation decision.

## Gate
No unrestricted automatic WhatsApp messages until Core, Central, provider credential, durable claim and owner UAT releases are all independently certified.
