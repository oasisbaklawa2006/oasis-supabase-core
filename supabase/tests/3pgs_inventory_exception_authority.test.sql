begin;

select plan(13);

select has_table(
  'public',
  'b2b_3pgs_inventory_exception_events',
  '3PGS inventory exception event ledger exists'
);

select has_function(
  'public',
  'record_b2b_3pgs_inventory_exception',
  array['uuid','text','text','text','numeric','text','text','jsonb'],
  'governed 3PGS inventory exception RPC exists'
);

select ok(
  (select prosecdef from pg_proc where oid = 'public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure),
  '3PGS inventory exception RPC is SECURITY DEFINER'
);

select ok(
  not has_table_privilege('anon', 'public.b2b_3pgs_inventory_exception_events', 'SELECT')
  and not has_table_privilege('anon', 'public.b2b_3pgs_inventory_exception_events', 'INSERT')
  and not has_table_privilege('anon', 'public.b2b_3pgs_inventory_exception_events', 'UPDATE')
  and not has_table_privilege('anon', 'public.b2b_3pgs_inventory_exception_events', 'DELETE'),
  'anon has no exception-ledger authority'
);

select ok(
  has_table_privilege('authenticated', 'public.b2b_3pgs_inventory_exception_events', 'SELECT')
  and not has_table_privilege('authenticated', 'public.b2b_3pgs_inventory_exception_events', 'INSERT')
  and not has_table_privilege('authenticated', 'public.b2b_3pgs_inventory_exception_events', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.b2b_3pgs_inventory_exception_events', 'DELETE'),
  'authenticated users can read but cannot directly mutate exception events'
);

select ok(
  has_function_privilege('authenticated', 'public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)', 'EXECUTE'),
  'only authenticated callers can reach the governed exception RPC'
);

select ok(
  pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%can_access_b2b_inventory_store(v_actor, ''3PGS'', ''manage'')%',
  'RPC enforces canonical 3PGS manage authority'
);

select ok(
  pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%WHERE correlation_id = btrim(p_correlation_id)%'
  and pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%Correlation id already belongs to a different inventory exception%',
  'RPC is idempotent and rejects correlation-key reuse with different semantics'
);

select ok(
  pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%available_qty = available_qty - p_quantity%'
  and pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%quarantine_qty = quarantine_qty + p_quantity%',
  'quarantine moves exact quantity from available to quarantine'
);

select ok(
  pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%quarantine_qty = quarantine_qty - p_quantity%'
  and pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%available_qty = available_qty + p_quantity%',
  'quarantine release moves exact quantity back to available'
);

select ok(
  pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%Insufficient available stock for inventory exception%'
  and pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%Insufficient quarantined stock for inventory exception%',
  'exception mutation fails closed on insufficient source bucket quantity'
);

select ok(
  pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%''stock_quarantined''%'
  and pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%''stock_quarantine_released''%'
  and pg_get_functiondef('public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure)
    like '%''correction_out''%',
  'exception actions append only existing canonical inventory movement types'
);

select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'b2b_3pgs_inventory_exception_events'
      and policyname = 'Internal staff read 3PGS inventory exception events'
      and cmd = 'SELECT'
  ),
  'exception ledger has an internal-staff read policy'
);

select * from finish();
rollback;
