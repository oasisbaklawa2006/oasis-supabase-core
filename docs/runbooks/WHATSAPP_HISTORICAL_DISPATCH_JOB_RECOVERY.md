# WA-RECOVERY-01: recovery of the five historical packet-AI dispatch jobs

Status: PLAN ONLY. Nothing in this document has been executed against production.
Evidence: read-only production queries on 2026-10-22 (project `tcxvcatsqqertcnycuop`), baseline
`97c06daf762881f1abd4ad599439362b9e1afb3a`. Counts are snapshots.

Repair migration: `20261022121000_whatsapp_materialize_non_order_ambiguity_tolerance`
(test: `supabase/tests/20261022121000_whatsapp_materialize_non_order_ambiguity_tolerance.sql`).

## Root causes

| Job | Packet | Failure | Root cause |
| --- | --- | --- | --- |
| `8803fe46-373d-49dc-aad1-19bf8ba02daa` | `55f8c388-4341-4648-b3ed-24be2ba740f0` (rev 18) | `INTERPRETATION_PACKET_TOO_LARGE` | 18 inbound images in one 4-minute burst; the worker caps a packet at 16 messages (`MAX_PACKET_MESSAGES`). Deterministic: retrying can never succeed. Sender is unidentified, case is `NEEDS_IDENTITY`. |
| `71ae66a5-22b3-4a6f-88b3-7738d2a8b116` | `b87a642a-03a0-4544-b0c0-fc1b25af26e6` (rev 2) | `CASE_MATERIALIZATION_FAILED` | Messages "Hi" and "Please send catalog". Each inbound message holds its own potential order, so the packet resolves to two. |
| `b427fcfa-8856-4caa-8388-6e6eec5b4ecf` | `814a6c76-0372-4331-93cf-74774ec45b69` (rev 2) | `CASE_MATERIALIZATION_FAILED` | Two third-party restaurant auto-marketing messages (not a customer order). Same two-potential-order shape. |
| `ac9b2cbe-cd58-4f78-a90e-c400b520e0b8` | `b5e1d52d-4c9c-4ada-9105-78fd95543061` (rev 4) | `CASE_MATERIALIZATION_FAILED` | Two documents, "Payment paid please send material tommrow", "KAL PLEASE BILTI DEDENGE BHAIYA ... TRAIN KA". Three potential orders. |
| `43945d46-2a98-44dc-b95a-d7ea4c32b4ae` | `da794d6c-5820-413e-ba83-25476bfb3be2` (rev 2) | `CASE_MATERIALIZATION_FAILED` | The same third-party marketing messages as `b427fcfa`, again on 2026-10-21. |

Shared mechanism for the four materialization failures: `whatsapp_materialize_packet_ai_case()` and
`whatsapp_evaluate_and_materialize_order_autonomy()` both called the strict resolver
`whatsapp_case_potential_order_id()` before the intent was known. The strict resolver raises when a case
links to more than one potential order, so non-order messages looped forever. All potential orders involved
are `FAILED_INTERPRETATION` or `AWAITING_CLARIFICATION`; none has a sales order or draft, so there is no
duplicate-order exposure. No outbound message was ever sent for any of the five packets.

## What the repair does (and does not)

- Non-order intents (explicit list, confidence >= 0.50) and the post-sales-order correction guard tolerate
  an ambiguous link **only when no linked potential order already has a sales order**.
- `ORDER`, `NEW_ORDER`, `UNCLEAR`, low-confidence and order-modification intents keep the strict failure,
  which #437 routes to governed human review (`AMBIGUOUS_POTENTIAL_ORDER_REVIEW`). No potential order is ever selected.
- The strict resolver is unchanged. No data is modified; no historical message or potential order is touched.

The repair is DB-only and takes effect for the live worker only after the migration is released. Until then the
four materialization jobs keep looping (about one attempt every 8 minutes each).

## Classification and recommended action

| Job | Classification | Recommended action |
| --- | --- | --- |
| `8803fe46` | GOVERNED_DEAD_LETTER (plus follow-up TECHNICAL_REPAIR) | Operator quarantine; a human triages the 18 images from the open `NEEDS_IDENTITY` case. Follow-up: a packet-chunking change in the Edge worker (not part of this PR). |
| `71ae66a5` | REQUIRES_HUMAN_CLARIFICATION | A person decides whether to answer the 17-day-old catalogue request. Dead-letter the job; do not requeue. |
| `b427fcfa` | GOVERNED_DEAD_LETTER | Third-party marketing, not a customer. Operator quarantine. |
| `43945d46` | GOVERNED_DEAD_LETTER | Same sender and content as `b427fcfa`. Operator quarantine. |
| `ac9b2cbe` | FINANCE_REVIEW | Finance verifies the payment against the bank record and identifies the customer first; the bilty/dispatch request follows. Dead-letter the job with the finance reference in the reason. |

Why not requeue after the fix: a successful materialization of a non-order packet can enqueue an
autonomous non-order receipt (`whatsapp_apply_non_order_case_governance_v1`, `NON_ORDER_RECEIPT`). Requeuing
would therefore send a WhatsApp message to a third-party marketing sender and a stale automated reply to
customers after 9-17 days. That is a live-message decision for a person, so the plan quarantines instead.

## Execution (requires explicit approval; service role)

Run in one transaction per job. Both RPCs are idempotent per key; `<operator>` is a real `users.id`.

```sql
begin;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.dead_letter_whatsapp_packet_ai_dispatch_job(
  '<full job uuid>', '<reason, >= 5 chars>', '<operator uuid>', 'wa-recovery-01:<job8>');
commit;
```

Expected transition per job: `RETRY` -> `DEAD_LETTERED`, `dead_letter_class = OPERATOR_QUARANTINE`, one
`OPERATOR_DEAD_LETTERED` row in `whatsapp_packet_ai_dispatch_dead_letter_events`, one open `dead_letter_entries` row.
If the RPC returns `false`, the job was not eligible and nothing changed (for example it is `LEASED` with an
unexpired lease because a worker is processing it). Roll back, wait for the lease to expire, and run the same
call again with the same key.
No change to messages, packets, cases or potential orders.

Rollback (reversible, audited): `requeue_whatsapp_packet_ai_dispatch_job(job, reason, operator, key)` resets
the budget. Do this only after the repair migration is live and a person has accepted that a receipt may be sent.

## Read-only verification queries

```sql
-- current state of the five jobs
select id, state, attempt_count, bounded_retry, dead_letter_class, dead_lettered_at
from public.whatsapp_packet_ai_dispatch_jobs
where id in ('8803fe46-373d-49dc-aad1-19bf8ba02daa','71ae66a5-22b3-4a6f-88b3-7738d2a8b116',
             'b427fcfa-8856-4caa-8388-6e6eec5b4ecf','ac9b2cbe-cd58-4f78-a90e-c400b520e0b8',
             '43945d46-2a98-44dc-b95a-d7ea4c32b4ae');
-- audit trail
select job_id, event_type, created_at from public.whatsapp_packet_ai_dispatch_dead_letter_events
where job_id in (select id from public.whatsapp_packet_ai_dispatch_jobs where state = 'DEAD_LETTERED');
-- nothing was lost or created
select (select count(*) from public.whatsapp_messages) messages,
       (select count(*) from public.whatsapp_potential_orders) potential_orders,
       (select count(*) from public.whatsapp_potential_orders where sales_order_id is not null) with_so;
select count(*) from public.whatsapp_operator_reply_outbox where created_at > now() - interval '1 hour';
```
