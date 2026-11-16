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

## Real Core order projection and verified recipient contract (November 2026)

The original legacy automation attempted to read `public.orders.customer_phone`, `total_value` and `advance_amount`, which do **not** exist in the authoritative Core order schema. The candidate now reads `order_number`, `sales_order_value`, `advance_required` and `company_id` only. **Never** choose `companies.phone` by inference as a WhatsApp recipient.

Before claiming an order event, the candidate demands exactly one nonexpired, `ACTIVE` `whatsapp_sender_commercial_authorizations` record for the order company with `sales_order` disclosure scope, a matching `whatsapp_contacts` phone, one `CONFIRMED` `whatsapp_case_identities` company identity, and effective `TRANSACTIONAL` consent `OPTED_IN` or `LEGITIMATE_SERVICE`. Opt-out, missing/ambiguous evidence, revoked authority or unenforced quiet-hour/daily frequency limits fail closed **before** the claim and provider send. Verify real production data shape and identity associations with independent business owners before enabling this policy; do not silently relax the contract just to permit sending. Read-only inspection found **zero commercial sender authorization rows and zero WhatsApp communication preference rows** in Core production on 16 Nov 2026, so onboarding and approval remain necessary.

The function has an independent default-off server-only switch `WA100_LEGACY_ORDER_AUTOMATION_SEND_ENABLED` and returns HTTP 503 `WA100_AUTOMATION_RELEASE_NOT_AUTHORIZED` unless it is exactly `true`. Never set it in a public client. Leave disabled until all Core schema, provider, consent, approved Meta template, quiet-hour/scheduling, production caller-policy and device UAT gates pass. Do not enable or send in preview just because a migration or function deploy succeeded.

Isolated #547 Supabase Preview deployed a named-function candidate with JWT verification enabled. This **does not** deploy the live v60 production automation. All production changes require named protected release and separately approved migration. No customer message was sent during preview SQL/idempotency and authorization tests.
