begin;
-- Contract for 20261125000000_tv_department_queue_product_identity_v1.sql:
-- tv_department_production_queue_named_v1() returns the caller's own department queue with product name + SKU.
select plan(16);

insert into auth.users (id, email) values
  ('15000000-0000-0000-0000-000000000001', 'admin-named@pgtap.invalid'),
  ('15000000-0000-0000-0000-000000000002', 'employee-named@pgtap.invalid'),
  ('15000000-0000-0000-0000-000000000003', 'tv-bakery-named@pgtap.invalid'),
  ('15000000-0000-0000-0000-000000000004', 'tv-rgs-named@pgtap.invalid');
insert into public.users (id, email, role) values
  ('15000000-0000-0000-0000-000000000001', 'admin-named@pgtap.invalid', 'super_admin'),
  ('15000000-0000-0000-0000-000000000002', 'employee-named@pgtap.invalid', 'PROD_ARABIC'),
  ('15000000-0000-0000-0000-000000000003', 'tv-bakery-named@pgtap.invalid', 'tv_ready'),
  ('15000000-0000-0000-0000-000000000004', 'tv-rgs-named@pgtap.invalid', 'tv_ready');

set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';
select public.register_tv_device('15000000-0000-0000-0000-000000000003', 'TV Bakery Named', 'BAKERY');
select public.register_tv_device('15000000-0000-0000-0000-000000000004', 'TV RGS Named', 'RGS');

-- Fixture: a bakery job with a product, a bakery job with NO product, a chocolates job, a completed bakery job.
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('25000000-0000-0000-0000-000000000001', 'Bakery Named Item', 'sweets', 'BK-NAMED-1', '1905', 'bakery'),
  ('25000000-0000-0000-0000-000000000002', 'Chocolate Named Item', 'sweets', 'CH-NAMED-1', '1806', 'chocolates_confectionery');
set local session_replication_role = replica;
insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('35000000-0000-0000-0000-000000000001', 'PGTAP-ORD-TVNAMED-1', 'pgtap-fixture-token-tvnamed-1', 'MANUAL');
set local session_replication_role = default;
insert into public.production_jobs (id, order_id, product_id, department, canonical_department, assigned_qty, status) values
  ('45000000-0000-0000-0000-000000000001', '35000000-0000-0000-0000-000000000001', '25000000-0000-0000-0000-000000000001', 'BAKERY', 'BAKERY', 5, 'pending'),
  ('45000000-0000-0000-0000-000000000002', '35000000-0000-0000-0000-000000000001', null, 'BAKERY', 'BAKERY', 3, 'pending'),
  ('45000000-0000-0000-0000-000000000003', '35000000-0000-0000-0000-000000000001', '25000000-0000-0000-0000-000000000002', 'CHOCOLATES_CONFECTIONERY', 'CHOCOLATES_CONFECTIONERY', 5, 'pending'),
  ('45000000-0000-0000-0000-000000000004', '35000000-0000-0000-0000-000000000001', '25000000-0000-0000-0000-000000000001', 'BAKERY', 'BAKERY', 2, 'completed');

-- A. shape and grants ------------------------------------------------------
select has_function('public', 'tv_department_production_queue_named_v1', array[]::text[], 'named queue RPC exists');
select is(
  (select prosecdef from pg_proc where oid = 'public.tv_department_production_queue_named_v1()'::regprocedure),
  true, 'named queue RPC is SECURITY DEFINER');
select ok(
  (select proconfig::text from pg_proc where oid = 'public.tv_department_production_queue_named_v1()'::regprocedure) like '%search_path=%',
  'named queue RPC pins an empty search_path');
select ok(
  has_function_privilege('authenticated', 'public.tv_department_production_queue_named_v1()', 'execute')
  and not has_function_privilege('anon', 'public.tv_department_production_queue_named_v1()', 'execute'),
  'authenticated can execute the named queue RPC; anon cannot');
select ok(not exists (
  select 1 from pg_proc p
  where p.oid = 'public.tv_department_production_queue_named_v1()'::regprocedure
    and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where a.privilege_type = 'EXECUTE' and a.grantee = 0)),
  'PUBLIC has no EXECUTE on the named queue RPC');
select is(
  pg_get_function_result('public.tv_department_production_queue_named_v1()'::regprocedure),
  'TABLE(id uuid, order_id uuid, product_id uuid, department text, assigned_qty numeric, produced_qty numeric, batch_number text, priority text, stage text, status text, created_at timestamp with time zone, product_name text, sku text)',
  'the named queue exposes only job columns plus product_name and sku');
select is(
  pg_get_function_result('public.tv_department_production_queue()'::regprocedure),
  'SETOF production_jobs',
  'the existing tv_department_production_queue() contract is unchanged');

-- B. non-TV caller reads nothing -------------------------------------------
set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000002';
select is((select count(*) from public.tv_department_production_queue_named_v1()), 0::bigint,
  'an ordinary staff account reads no rows');

-- C. the bakery TV device ----------------------------------------------------
set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000003';
select is(
  (select product_name || '|' || sku from public.tv_department_production_queue_named_v1()
    where id = '45000000-0000-0000-0000-000000000001'),
  'Bakery Named Item|BK-NAMED-1',
  'the bakery TV device sees its own job with the product name and SKU');
select is(
  (select count(*) from public.tv_department_production_queue_named_v1()
    where id = '45000000-0000-0000-0000-000000000003'),
  0::bigint, 'the bakery TV device cannot read another department''s job');
select is(
  (select count(*) from public.tv_department_production_queue_named_v1()
    where id = '45000000-0000-0000-0000-000000000004'),
  0::bigint, 'a completed job is not in the active queue');
select ok(
  exists (select 1 from public.tv_department_production_queue_named_v1()
           where id = '45000000-0000-0000-0000-000000000002' and product_name is null and sku is null),
  'a job with no product still appears, with a null name and SKU (never dropped)');
select is(
  (select array_agg(id order by id) from public.tv_department_production_queue_named_v1()),
  (select array_agg(id order by id) from public.tv_department_production_queue()),
  'the named queue returns exactly the same job rows as the existing queue');

-- D. RGS device has its own surface -------------------------------------------
set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000004';
select is((select count(*) from public.tv_department_production_queue_named_v1()), 0::bigint,
  'the RGS TV device reads no rows from the department queue');

-- E. a disabled device reads nothing ------------------------------------------
set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000001';
select public.disable_tv_device(
  (select id from public.tv_devices where auth_user_id = '15000000-0000-0000-0000-000000000003'), 'pgTAP disable check');
set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000003';
select is((select count(*) from public.tv_department_production_queue_named_v1()), 0::bigint,
  'a disabled bakery TV device reads no rows');

-- F. no unauthenticated access ----------------------------------------------------
reset role;
set local request.jwt.claim.sub = '';
select is((select count(*) from public.tv_department_production_queue_named_v1()), 0::bigint,
  'a caller with no authenticated identity reads no rows');

select * from finish();
rollback;
