# Buyer #64 — disposable GitHub-linked Supabase UAT preview

Status: PROVISIONING / NOT CERTIFIED. Owning issues: Core #495; Buyer #64.
Base Core main commit: `c7a57e0b0041a28a63193e851d47912b0a6a2840`.
Purpose: recover an isolated, schema-complete **GitHub-repository-based** preview without
replaying the irreconcilable historical production SQL stored in Supabase's
database migration ledger (Dashboard-created branches fail at version
`20260316122451` before `public.orders` exists).

This is a **temporary certification branch**, not a proposed permanent product
change. It adds only this document and a comment to `supabase/config.toml`
to exercise the native Supabase GitHub integration when "Supabase changes only"
is enabled. It must **not be merged**. Production migration, secrets, runtime,
functions and deployment configuration must remain unchanged.

## Immutable safety rules

- Production project ref `tcxvcatsqqertcnycuop` is never an acceptable
  Buyer UAT backend. No production customer/order/payment writes or OTP tests.
- Preview must have its **own** Supabase ref, API URL and publishable client key;
  no production-key fallback or copied customer PII. Buyer native build-time
  and runtime guards from merged Buyer PRs #71 and #72 must both verify the ref.
- All mutations use synthetic users, companies, products, drafts and orders
  in the isolated preview **only after** schema, permission, financial and
  other workstream segregation checks pass. Real MSG91/OTP provider testing
  requires separately approved test configuration and physical device.
- This branch is no place to deploy WhatsApp production webhooks, payments,
  scheduled jobs or traffic. Provider sends and external callbacks stay OFF.
- No manually issued schema deployment, migration-history manipulation,
  privileged SQL, or production write may be used to make a preview pass.
- Preview branch should be deleted as soon as its tests are recorded or if
  provisioning fails, to terminate hourly compute charges.

## Minimum acceptance evidence

1. Trusted `Supabase Preview` check: exact current PR SHA, status SUCCESS,
   preview ref not equal to production, GitHub branch association.
2. Preview `FUNCTIONS_DEPLOYED` (not merely `ACTIVE_HEALTHY`), populated
   canonical `public.orders`, `public.products`, required quote RPCs.
3. Full expected Core canonical Git migration replay through
   `20261101040000_customer_checkout_legacy_submit_quote_consent_barrier_v1`.
   Do not require identical migration *version sets* to production: historic
   production-only versions and canonical no-op/forward replacements are
   reconciled under Core's protected lineage mapping. Instead check current
   canonical Git set and relevant semantic schema/ACL parity.
4. Role/ACL probes: authenticated and anon cannot EXECUTE
   `submit_customer_order_v1(text,date)`; authenticated can execute
   `customer_checkout_quote_v1()` and
   `submit_customer_order_quoted_v1(text,text,date)`.
5. Authenticated isolated PostgREST negative 403 legacy submit; correct
   quote fingerprint accepted once; stale/altered quote and cross-tenant
   submissions fail closed; idempotency and commercial/tax/SO invariants
   checked with clean synthetic fixtures. Record exact software SHA.
6. Buyer EAS preview APK contains only isolated project ref/key; actual
   Android installation, MSG91 test OTP, logout/session, quote acceptance
   and checkout/returns negative cases captured with owner-approved UAT.
7. Archive reproducible and redacted evidence in Buyer #64 and Core #495,
   explicitly record resource cleanup, and hold launch until physical signoff.

Current PASS evidence from canonical local CI Core #496 does **not** substitute
for these hosted/backend/device acceptance gates.
