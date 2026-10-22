# WhatsApp packet-AI dispatch: bounded retry and dead-letter

Migration: `20261022120000_whatsapp_packet_ai_dispatch_bounded_retry`.
Contract tests: `supabase/tests/20261022120000_whatsapp_packet_ai_dispatch_bounded_retry.sql`,
`scripts/test-whatsapp-packet-ai-retry-two-session-race.sh`.

## Behaviour

| Failure | Result |
| --- | --- |
| `INTERPRETATION_PACKET_TOO_LARGE`, `PACKET_EMPTY`, `CASE_CONTEXT_EMPTY`, `PACKET_NOT_FOUND`, `PACKET_MEDIA_TOO_LARGE`, `KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE` (the deployed worker flags it as a knowledge-authority failure; bounded jobs classify it first) | `DEAD_LETTERED` / `DETERMINISTIC` on first occurrence |
| `CASE_MATERIALIZATION_FAILED` with "multiple potential orders are linked" | `DEAD_LETTERED` / `HUMAN_REVIEW_REQUIRED` on first occurrence; one OPEN `AMBIGUOUS_POTENTIAL_ORDER_REVIEW` task for `OPERATIONS`. No order is ever selected automatically. |
| `INTERPRETER_INVALID_SCHEMA`, `INTERPRETER_INVALID_JSON` | retried, budget from `whatsapp.packet_ai_dispatch.model_output` (default 3), then `RETRY_EXHAUSTED` |
| Any other failure, and worker lease expiry (crash or timeout) | retried, budget from `whatsapp.packet_ai_dispatch.default` (default 10), then `RETRY_EXHAUSTED` |
| Other knowledge-authority blocks (`KNOWLEDGE_SNAPSHOT_*` except `KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE`) | unchanged (`BLOCKED_KNOWLEDGE_AUTHORITY`) |

Budgets are rows in `retry_policies`, tunable without a code change. A dead
letter writes, in one transaction: the job terminal state, an append-only
`whatsapp_packet_ai_dispatch_dead_letter_events` row, and an open
`dead_letter_entries` row (platform console).

Jobs that existed before the migration are **not** dead-lettered automatically.
They have `bounded_retry = false` and keep their previous behaviour until an
operator acts or a new inbound message revises the packet (which enrols them).

## Operator procedures (service role)

Both RPCs require a service-role caller. Call them through PostgREST with the
service key, or, from psql / the SQL editor, set the claim first in the same
transaction:

```sql
begin;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);

-- Park a historical looping job (reversible). A job that is crash-looping in
-- LEASED is accepted once its lease has expired.
select public.dead_letter_whatsapp_packet_ai_dispatch_job(
  '<job_id>', '<reason, >= 5 chars>', '<operator uuid>', '<unique idempotency key>');

-- Resume a dead-lettered job with a fresh budget (reversible, audited).
select public.requeue_whatsapp_packet_ai_dispatch_job(
  '<job_id>', '<reason>', '<operator uuid>', '<unique idempotency key>');

-- Inspect (service role): terminal jobs and jobs retrying or crash-looping past 10 attempts.
select * from public.whatsapp_packet_ai_dispatch_exceptions_v;
commit;
```

Both RPCs are idempotent per key. A new inbound message on a dead-lettered
packet also revives the job automatically (audited as `REVIVED_BY_NEW_REVISION`).

## Rollback

The migration is additive; do not edit or delete it. To revert behaviour,
ship a forward migration that re-creates the previous definitions verbatim
(`retry_whatsapp_packet_ai_dispatch_job` from `20260822110000`,
`claim_whatsapp_packet_ai_dispatch_job` from `20260919150000`) and drops the
revive trigger. The new columns, event table and policy rows are inert once
the functions no longer reference them. Dead-lettered jobs must first be
re-queued with `requeue_whatsapp_packet_ai_dispatch_job`, because the previous
claim function does not know the `DEAD_LETTERED` state.
