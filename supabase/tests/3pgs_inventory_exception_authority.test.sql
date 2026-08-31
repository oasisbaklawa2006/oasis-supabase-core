begin;
-- Contract coverage for 20260901002000_3pgs_inventory_exception_authority.sql.
-- R4.4 must prove behavior, not only function-source text.
select plan(25);

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

select ok(
  (
    with def as (
      select pg_get_functiondef(
        'public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)'::regprocedure
      ) as body
    )
    select strpos(body, '3pgs-exception:') > 0
      and strpos(body, '3pgs-exception:') < strpos(body, 'WHERE correlation_id = btrim(p_correlation_id)')
    from def
  ),
  'correlation advisory lock is acquired before replay lookup so concurrent retries serialize'
);

-- Deterministic execution fixture. The transaction rolls all fixture state back.
insert into public.users(id, role, name, email)
values (
  '00000000-0000-0000-0000-00000000a161'::uuid,
  'ADMIN',
  'R4.4 pgTAP manager',
  'r4-4-pgtap-manager@example.invalid'
)
on conflict (id) do update set role = excluded.role;

insert into public.products(
  id, name, category, sku, hsn_code, primary_pack_weight_kg
)
values (
  '00000000-0000-0000-0000-00000000b161'::uuid,
  'R4.4 3PGS exception fixture',
  'Packaging',
  'TEST-3PGS-EXCEPTION-161',
  '4819',
  1
)
on conflict (id) do nothing;

insert into public.inventory_stock_balances(
  product_id, sku, location_code, available_qty, quarantine_qty
)
values (
  '00000000-0000-0000-0000-00000000b161'::uuid,
  'TEST-3PGS-EXCEPTION-161',
  '3PGS',
  10,
  2
)
on conflict (product_id, sku, location_code) do update
set available_qty = 10,
    quarantine_qty = 2,
    reserved_qty = 0,
    damaged_qty = 0,
    expired_qty = 0,
    picked_qty = 0,
    version = inventory_stock_balances.version + 1,
    updated_at = now();

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-00000000a161',
  true
);

select lives_ok(
  $$
  select public.record_b2b_3pgs_inventory_exception(
    '00000000-0000-0000-0000-00000000b161'::uuid,
    'TEST-3PGS-EXCEPTION-161',
    'quarantine',
    'available',
    3,
    'QC hold after GRN',
    'r4.4:test:quarantine:1',
    '[{"kind":"qc_photo"}]'::jsonb
  )
  $$,
  'quarantine action executes through governed RPC'
);

select is(
  (select available_qty::text from public.inventory_stock_balances
   where product_id='00000000-0000-0000-0000-00000000b161'::uuid
     and sku='TEST-3PGS-EXCEPTION-161' and location_code='3PGS'),
  '7',
  'quarantine decrements available quantity exactly once'
);

select is(
  (select quarantine_qty::text from public.inventory_stock_balances
   where product_id='00000000-0000-0000-0000-00000000b161'::uuid
     and sku='TEST-3PGS-EXCEPTION-161' and location_code='3PGS'),
  '5',
  'quarantine increments quarantine quantity exactly once'
);

select lives_ok(
  $$
  select public.record_b2b_3pgs_inventory_exception(
    '00000000-0000-0000-0000-00000000b161'::uuid,
    'TEST-3PGS-EXCEPTION-161',
    'quarantine',
    'available',
    3,
    'QC hold after GRN',
    'r4.4:test:quarantine:1',
    '[{"kind":"qc_photo"}]'::jsonb
  )
  $$,
  'same-correlation retry replays successfully'
);

select is(
  (select count(*)::text from public.b2b_3pgs_inventory_exception_events
   where correlation_id='r4.4:test:quarantine:1'),
  '1',
  'same-correlation retry does not duplicate exception event'
);

select is(
  (select count(*)::text from public.inventory_movements
   where correlation_id='r4.4:test:quarantine:1:movement'),
  '1',
  'same-correlation retry does not duplicate inventory movement'
);

select is(
  (select available_qty::text from public.inventory_stock_balances
   where product_id='00000000-0000-0000-0000-00000000b161'::uuid
     and sku='TEST-3PGS-EXCEPTION-161' and location_code='3PGS'),
  '7',
  'same-correlation retry does not mutate available quantity twice'
);

select is(
  (select quarantine_qty::text from public.inventory_stock_balances
   where product_id='00000000-0000-0000-0000-00000000b161'::uuid
     and sku='TEST-3PGS-EXCEPTION-161' and location_code='3PGS'),
  '5',
  'same-correlation retry does not mutate quarantine quantity twice'
);

select throws_ok(
  $$
  select public.record_b2b_3pgs_inventory_exception(
    '00000000-0000-0000-0000-00000000b161'::uuid,
    'TEST-3PGS-EXCEPTION-161',
    'quarantine',
    'available',
    4,
    'QC hold after GRN',
    'r4.4:test:quarantine:1',
    '[{"kind":"qc_photo"}]'::jsonb
  )
  $$,
  'P0001',
  'Correlation id already belongs to a different inventory exception',
  'correlation-key reuse with different semantics fails closed'
);

select lives_ok(
  $$
  select public.record_b2b_3pgs_inventory_exception(
    '00000000-0000-0000-0000-00000000b161'::uuid,
    'TEST-3PGS-EXCEPTION-161',
    'release_quarantine',
    'quarantine',
    2,
    'QC cleared',
    'r4.4:test:release:1',
    '[]'::jsonb
  )
  $$,
  'quarantine release executes through governed RPC'
);

select is(
  (select available_qty::text from public.inventory_stock_balances
   where product_id='00000000-0000-0000-0000-00000000b161'::uuid
     and sku='TEST-3PGS-EXCEPTION-161' and location_code='3PGS'),
  '9',
  'quarantine release restores exact quantity to available'
);

select is(
  (select quarantine_qty::text from public.inventory_stock_balances
   where product_id='00000000-0000-0000-0000-00000000b161'::uuid
     and sku='TEST-3PGS-EXCEPTION-161' and location_code='3PGS'),
  '3',
  'quarantine release decrements quarantine exactly'
);

select lives_ok(
  $$
  select public.record_b2b_3pgs_inventory_exception(
    '00000000-0000-0000-0000-00000000b161'::uuid,
    'TEST-3PGS-EXCEPTION-161',
    'damage_writeoff',
    'available',
    2,
    'Broken after handling',
    'r4.4:test:damage:1',
    '[]'::jsonb
  )
  $$,
  'damage write-off executes from available stock'
);

select is(
  (select available_qty::text from public.inventory_stock_balances
   where product_id='00000000-0000-0000-0000-00000000b161'::uuid
     and sku='TEST-3PGS-EXCEPTION-161' and location_code='3PGS'),
  '7',
  'damage write-off removes exact available quantity'
);

select lives_ok(
  $$
  select public.record_b2b_3pgs_inventory_exception(
    '00000000-0000-0000-0000-00000000b161'::uuid,
    'TEST-3PGS-EXCEPTION-161',
    'return_to_vendor',
    'quarantine',
    1,
    'Supplier return approved',
    'r4.4:test:rtv:1',
    '[]'::jsonb
  )
  $$,
  'return-to-vendor executes from quarantine stock'
);

select is(
  (select quarantine_qty::text from public.inventory_stock_balances
   where product_id='00000000-0000-0000-0000-00000000b161'::uuid
     and sku='TEST-3PGS-EXCEPTION-161' and location_code='3PGS'),
  '2',
  'return-to-vendor removes exact quarantined quantity'
);

select throws_ok(
  $$
  select public.record_b2b_3pgs_inventory_exception(
    '00000000-0000-0000-0000-00000000b161'::uuid,
    'TEST-3PGS-EXCEPTION-161',
    'damage_writeoff',
    'available',
    99,
    'Impossible overdraw',
    'r4.4:test:overdraw:1',
    '[]'::jsonb
  )
  $$,
  'P0001',
  'Insufficient available stock for inventory exception',
  'insufficient source bucket quantity fails closed'
);

select * from finish();
rollback;
