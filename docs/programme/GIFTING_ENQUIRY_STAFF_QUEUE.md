# Gifting enquiry staff queue (GFT-100 / Central #677)

Stacked on the receiver (Core PR #557). Core owns data and authorization; Central owns the staff UI.

## Contract
`gifting_enquiries` stays `service_role`-only. Staff use two `SECURITY DEFINER` RPCs that run
`gifting_enquiry_queue_authorized()` first:

| RPC | Purpose |
|---|---|
| `gifting_enquiry_queue_list_v1(p_status, p_limit 1..100, p_offset)` | newest first; returns triage fields only (no idempotency hash, consumer id, source lead id or attribution) |
| `gifting_enquiry_queue_set_status_v1(p_enquiry_id, p_status)` | `received` / `triaged` / `closed` / `spam`; records `status_changed_by` (`auth.uid()`) and `status_changed_at`; never deletes |

Errors: `GIFTING_QUEUE_FORBIDDEN` (42501), `GIFTING_QUEUE_INVALID` (22023), `GIFTING_QUEUE_NOT_FOUND` (P0002).
`anon` cannot execute either RPC; `authenticated` can, and is rejected inside unless authorized.

## Permission: decision needed
Implemented with the **narrowest existing rule**: an active `admin` or `super_admin` (`public.is_admin()`). Ordinary staff
(for example `support_executive`), inactive admins and anonymous callers are rejected (tested).

Proposal for approval: also allow the role(s) that follow up D2C leads (for example `sales_manager`) by changing only the body of
`gifting_enquiry_queue_authorized()` in a forward migration. This exposes enquirer name, email, phone and message, so it needs an
explicit owner decision. Not changed here.

## Retention and deletion: decision needed
No retention rule exists for D2C enquiry personal data. Proposal: keep `received`/`triaged` indefinitely while open; anonymise
`closed` and `spam` rows (null name/email/phone/company/message, keep kind/source/timestamps/status) after N days, N to be set by the
owner/legal. Not implemented because N and the legal basis are policy.

## Tenancy
The queue is single-tenant (Oasis D2C); there is no company/tenant column, matching Core's current model for D2C. Each row records
its Connect `consumer_id` and `environment`.
