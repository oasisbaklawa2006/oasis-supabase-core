# WA-100 order notification command — staging-only contract

**Issue:** Core #540. **Release:** DRAFT / NOT FOR PRODUCTION.  
**Authority:** `oasis-supabase-core` only. No browser-side provider call.

## Purpose

Stage a durable, immutable, recipient-bound **command identity** for order
notifications, without granting any authorization to transmit them. The
pre-existing `whatsapp_operator_reply_outbox` remains authoritative for
packet-linked operator replies; this narrower command is only for Core-owned
order lifecycle events not associated with a packet. It must not replace or
silently duplicate operator, dispatch or existing legacy notification logic.

## Database contract

- Tables: `wa100_utility_template_registry`,
  `wa100_order_notification_commands`, and
  append-only-style `wa100_order_notification_command_events`.
- RPC: `enqueue_wa100_order_notification_v1(order_id,event_type,contact_id,
  template_name,language_code,event_revision)`. Service role only.
- Supported in this foundation: `SO_CREATED`, `PAYMENT_VERIFIED`.
  **Dispatch is intentionally excluded** pending immutable gate-proof/version
  identity and independently approved physical-flow mapping.
- Event key: `wa100:v1:<order-uuid>:<event-type>:<revision>`.
  Database unique constraint also locks `(order_id,event_type,event_revision)`.
  A retry with different contact, company, identity or template fails closed.
- Cannot accept a browser/customer-submitted phone, message body, amount,
  consent flag, provider acceptance, delivery claim or arbitrary event key.
- Recipient must match one active commercial authorization bound to the
  actual order company and one confirmed company WhatsApp identity.
- Latest effective transactional preference must explicitly be `OPTED_IN`;
  unknown quiet-hour/frequency policies, expiry or missing consent are denied.
  This intentionally errs on the side of refusing messaging until business
  rules are approved.
- Template registry is initially empty and template entries default to
  `enabled=false`. Enabling metadata requires provider approval reference,
  approver and approval timestamp. **Even an enabled template cannot send in
  this release:** commands remain `NOT_SENT_RELEASE_GATED`.
- Every command status is constrained to `NOT_SENT_RELEASE_GATED`; no
  provider or delivery callback is called, no queue item is sent, and no
  delivery, billing, finance, order or dispatch row is updated.
- Tables are RLS enabled, private to service role; no `anon` or
  `authenticated` CRUD grants. Explicit BEFORE UPDATE/DELETE triggers reject
  mutation of both commands and audit events even by privileged application roles.

## Explicit remaining work — no certification claim

1. Independent security/code-owner review and exact-head clean migration replay
   plus pgTAP negative rights checks.
2. Resolve real Click2API CRM HTTP 401, supported authentication, signed or
   otherwise independently validated provider callbacks, and queue-ID to
   Meta wamid correlation. Credentials must never be transmitted in issues.
3. Freeze approved Meta utility templates, language, variable renderer and
   financial-disclosure policy; build **a separate reviewed release** to
   activate allowed template/event pairs.
4. Add a lease-safe server worker and acceptance-unknown/reconciliation
   transitions using provider observations, *never* automatic replay of
   uncertain sends.
5. Integrate Central caller-specific order and dispatch command adapters.
   Dispatch must use gate proof and version, not `companies.phone`, CRM notes,
   or invoice complaint-window timestamps as send keys.
6. Prove consent/revocation, wrong-company/branch, duplicate concurrent
   enqueue, template mismatch, callback spoofing, outage and device UAT.
7. Protected Supabase deployment, rollback, second-person approval and
   controlled per-event enablement before any production messaging.

## Current application presentation

Until a separately certified, durable accepted receipt exists, Central must
present **WhatsApp NOT SENT — release gated**. A saved command identity
does not mean queued, accepted or delivered.

**NO MERGE, NO PRODUCTION MIGRATION, NO SENDING ENABLEMENT IN THIS STAGING PR.**
