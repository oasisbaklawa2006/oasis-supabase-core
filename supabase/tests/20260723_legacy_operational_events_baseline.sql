begin;

select plan(8);

select has_table('public', 'operational_events',
  'legacy operational_events baseline exists');

select has_column('public', 'operational_events', 'event_type',
  'operational_events has event_type');

select has_column('public', 'operational_events', 'correlation_id',
  'operational_events has correlation_id');

select has_column('public', 'operational_events', 'idempotency_key',
  'operational_events has idempotency_key');

select col_is_pk('public', 'operational_events', 'id',
  'operational_events id is the primary key');

select has_function('public', 'prevent_operational_event_mutation', array[]::text[],
  'append-only mutation guard exists');

select ok(
  exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.operational_events'::regclass
      and tgname = 'trg_operational_events_no_update'
      and not tgisinternal
  ),
  'operational_events update guard trigger exists'
);

select ok(
  exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.operational_events'::regclass
      and tgname = 'trg_operational_events_no_delete'
      and not tgisinternal
  ),
  'operational_events delete guard trigger exists'
);

select * from finish();
rollback;
