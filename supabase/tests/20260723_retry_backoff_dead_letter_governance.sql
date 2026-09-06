-- Contract and behavioral coverage for Point 24 shared integration retry / dead-letter authority.
-- Schema authority: squashed baseline 20260723161256 + archived 20260723162000.
begin;

select plan(29);

select has_function(
  'public',
  'calculate_retry_delay_v1',
  array['text', 'integer', 'text'],
  'calculate_retry_delay_v1 canonical backoff writer exists'
);

select has_function(
  'public',
  'record_dead_letter_v1',
  array[
    'text', 'text', 'text', 'text', 'text', 'integer',
    'text', 'text', 'text', 'jsonb'
  ],
  'record_dead_letter_v1 canonical dead-letter writer exists'
);

select has_function(
  'public',
  'resolve_dead_letter_v1',
  array['uuid', 'text', 'text'],
  'resolve_dead_letter_v1 canonical resolver exists'
);

select ok(
  exists(
    select 1
    from public.retry_policies
    where policy_key = 'notification.delivery.default'
      and is_active
      and dead_letter_enabled
  ),
  'notification.delivery.default retry policy is active'
);

select ok(
  exists(
    select 1
    from public.retry_policies
    where policy_key = 'whatsapp.delivery.default'
      and is_active
  ),
  'whatsapp.delivery.default retry policy is registered'
);

select ok(
  exists(
    select 1
    from pg_class idx
    join pg_namespace ns on ns.oid = idx.relnamespace
    join pg_index i on i.indexrelid = idx.oid
    join pg_class tbl on tbl.oid = i.indrelid
    where ns.nspname = 'public'
      and idx.relname = 'dead_letter_open_source_uidx'
      and tbl.relname = 'dead_letter_entries'
      and i.indisunique
      and i.indpred is not null
  ),
  'open dead-letter source uniqueness index exists'
);

select ok(
  public.calculate_retry_delay_v1('notification.delivery.default', 1, 'point24-contract') >= 0,
  'retry delay for attempt 1 is non-negative'
);

select ok(
  public.calculate_retry_delay_v1('notification.delivery.default', 2, 'point24-contract')
    > public.calculate_retry_delay_v1('notification.delivery.default', 1, 'point24-contract'),
  'retry delay increases between attempts 1 and 2'
);

select ok(
  public.calculate_retry_delay_v1('notification.delivery.default', 20, 'point24-contract') <= 3600,
  'retry delay remains capped at policy max_delay_seconds'
);

select is(
  public.calculate_retry_delay_v1('notification.delivery.default', 2, 'point24-seed-a'),
  public.calculate_retry_delay_v1('notification.delivery.default', 2, 'point24-seed-a'),
  'retry delay is deterministic for a fixed jitter seed'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.record_dead_letter_v1(text,text,text,text,text,integer,text,text,text,jsonb)',
    'EXECUTE'
  ),
  'anon cannot record dead letters'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.record_dead_letter_v1(text,text,text,text,text,integer,text,text,text,jsonb)',
    'EXECUTE'
  ),
  'authenticated cannot record dead letters'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.record_dead_letter_v1(text,text,text,text,text,integer,text,text,text,jsonb)',
    'EXECUTE'
  ),
  'service_role can record dead letters'
);

insert into public.users (id, role) values
  ('a0240000-0000-0000-0000-000000000001', 'HOD_ARABIC'),
  ('a0240000-0000-0000-0000-000000000002', 'B2B_BUYER')
on conflict (id) do update set role = excluded.role;

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local role service_role;

select is(
  public.record_dead_letter_v1(
    'point24-pgtap',
    'notification_delivery',
    'notification_outbox',
    'point24-dl-1',
    'notification.delivery.default',
    2,
    'first failure',
    'POINT24_TEST',
    'point24-idem-dl',
    jsonb_build_object('probe', true)
  ),
  public.record_dead_letter_v1(
    'point24-pgtap',
    'notification_delivery',
    'notification_outbox',
    'point24-dl-1',
    'notification.delivery.default',
    3,
    'second failure',
    'POINT24_TEST',
    'point24-idem-dl',
    jsonb_build_object('probe', true)
  ),
  'repeated open dead-letter recording returns the same identity'
);

select is(
  (select attempt_count::integer
   from public.dead_letter_entries
   where source_table = 'notification_outbox'
     and source_record_id = 'point24-dl-1'
     and status = 'open'),
  3,
  'repeated dead-letter recording preserves the greatest attempt_count'
);

select is(
  public.enqueue_notification_v1(
    'point24-pgtap',
    'point24.retry.probe',
    'email',
    'Point24 retry probe body',
    'point24-notify-idem',
    'probe@example.com',
    null,
    'normal',
    null,
    2,
    now()
  ),
  public.enqueue_notification_v1(
    'point24-pgtap',
    'point24.retry.probe',
    'email',
    'Point24 retry probe body',
    'point24-notify-idem',
    'probe@example.com',
    null,
    'normal',
    null,
    2,
    now()
  ),
  'notification enqueue is idempotent for the same idempotency key'
);

create temporary table point24_notification as
select id
from public.enqueue_notification_v1(
  'point24-pgtap',
  'point24.retry.probe',
  'email',
  'Point24 retry probe body',
  'point24-notify-idem',
  'probe@example.com',
  null,
  'normal',
  null,
  2,
  now()
) as id;

create temporary table point24_claim as
select *
from public.claim_notification_batch_v1('point24-worker', 1, 120);

select is(
  (select status from point24_claim),
  'processing',
  'notification claim moves row into processing'
);

select is(
  public.fail_notification_v1(
    (select id from point24_notification),
    'point24-worker',
    'transient provider failure',
    0
  ),
  'retry',
  'non-terminal notification failure schedules retry'
);

select is(
  (select status from public.notification_outbox where id = (select id from point24_notification)),
  'retry',
  'notification retry status is persisted'
);

create temporary table point24_claim_2 as
select *
from public.claim_notification_batch_v1('point24-worker', 1, 120);

select is(
  (select attempt_count::integer from point24_claim_2),
  2,
  'second notification claim increments attempt_count'
);

select is(
  public.fail_notification_v1(
    (select id from point24_notification),
    'point24-worker',
    'terminal provider failure'
  ),
  'failed',
  'final notification attempt becomes failed'
);

select isnt(
  (
    select id
    from public.dead_letter_entries
    where source_table = 'notification_outbox'
      and source_record_id = (select id::text from point24_notification)
      and status = 'open'
  ),
  null::uuid,
  'final notification failure creates an open dead-letter entry'
);

select lives_ok(
  $$select public.resolve_dead_letter_v1(
    (select id from public.dead_letter_entries where source_record_id = 'point24-dl-1' and status = 'open'),
    'resolved',
    'point24 contract resolution'
  )$$,
  'service_role can resolve an open dead-letter entry'
);

select is(
  (select status from public.dead_letter_entries where source_record_id = 'point24-dl-1'),
  'resolved',
  'resolved dead-letter entry records terminal status'
);

reset role;
set local request.jwt.claim.sub = 'a0240000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select isnt_empty(
  $$select 1 from public.dead_letter_entries where source_record_id = 'point24-dl-1'$$,
  'staff authenticated role can read dead letters under RLS'
);

select isnt_empty(
  $$select 1 from public.retry_policies where policy_key = 'notification.delivery.default'$$,
  'staff authenticated role can read retry policies under RLS'
);

set local request.jwt.claim.sub = 'a0240000-0000-0000-0000-000000000002';

select is_empty(
  $$select 1 from public.dead_letter_entries where source_record_id = 'point24-dl-1'$$,
  'non-staff authenticated role cannot read dead letters under RLS'
);

select is_empty(
  $$select 1 from public.retry_policies$$,
  'non-staff authenticated role cannot read retry policies under RLS'
);

select throws_ok(
  $$select public.calculate_retry_delay_v1('notification.delivery.default', 0, 'point24-invalid')$$,
  'attempt_count must be positive',
  'retry delay rejects non-positive attempt counts'
);

select * from finish();
rollback;
