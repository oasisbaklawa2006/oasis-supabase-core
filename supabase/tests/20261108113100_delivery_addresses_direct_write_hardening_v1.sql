-- Contract test for 20261108113100_delivery_addresses_direct_write_hardening_v1.sql
begin;

select plan(24);

create temp table _ids (k text primary key, v uuid);
grant all on _ids to public;
do $$
declare v_a uuid; v_b uuid; v_f uuid;
  v_a1 uuid := gen_random_uuid(); v_ap uuid := gen_random_uuid(); v_ar uuid := gen_random_uuid(); v_b1 uuid := gen_random_uuid(); v_f1 uuid := gen_random_uuid(); v_st uuid := gen_random_uuid();
begin
  set local session_replication_role = replica;
  insert into public.companies (business_name, status, is_frozen) values ('Harden Co A', 'active', false) returning id into v_a;
  insert into public.companies (business_name, status, is_frozen) values ('Harden Co B', 'active', false) returning id into v_b;
  insert into public.companies (business_name, status, is_frozen) values ('Harden Co Frozen', 'active', true) returning id into v_f;
  insert into auth.users (id, email) values (v_a1,'hd-a1@example.com'),(v_ap,'hd-ap@example.com'),(v_ar,'hd-ar@example.com'),(v_b1,'hd-b1@example.com'),(v_f1,'hd-f1@example.com'),(v_st,'hd-st@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email) values
    (v_a1, v_a, 'b2b_buyer', true,  'approved', 'hd-a1@example.com'),
    (v_ap, v_a, 'b2b_buyer', false, 'pending',  'hd-ap@example.com'),
    (v_ar, v_a, 'b2b_buyer', false, 'rejected', 'hd-ar@example.com'),
    (v_b1, v_b, 'b2b_buyer', true,  'approved', 'hd-b1@example.com'),
    (v_f1, v_f, 'b2b_buyer', true,  'approved', 'hd-f1@example.com'),
    (v_st, null, 'admin', true, 'approved', 'hd-st@example.com');
  insert into public.delivery_addresses (id, company_id, label, street_address, city, state, pincode, is_default) values
    (gen_random_uuid(), v_a, 'Seed A', '1 A St', 'Pune', 'MH', '411001', true) ;
  insert into _ids values ('co_a', v_a), ('co_b', v_b), ('co_f', v_f), ('a1', v_a1), ('ap', v_ap), ('ar', v_ar), ('b1', v_b1), ('f1', v_f1), ('st', v_st), ('new', gen_random_uuid()), ('tr', gen_random_uuid());
  insert into _ids select 'seed', id from public.delivery_addresses where company_id = v_a limit 1;
  insert into public.delivery_addresses (id, company_id, label, street_address, city, state, pincode, is_default) values (gen_random_uuid(), v_f, 'Seed F', '1 F St', 'Delhi', 'DL', '110001', true);
  set local session_replication_role = origin;
end $$;
create or replace function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
end $$;
create or replace function pg_temp.id(p text) returns uuid language sql as $$ select v from _ids where k = p $$;
grant execute on function pg_temp.act_as(uuid), pg_temp.id(text) to public;

-- Policies and privileges ---------------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'delivery_addresses'), 2, 'only two policies remain on delivery_addresses');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'delivery_addresses' and cmd = 'SELECT'), 2, 'both remaining policies are SELECT policies');
select ok((select relrowsecurity and not relforcerowsecurity from pg_class where oid = 'public.delivery_addresses'::regclass), 'RLS stays enabled and not forced (definer RPCs keep writing)');
select ok(not exists (select 1 from unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p where has_table_privilege('anon', 'public.delivery_addresses', p)), 'anon holds no privilege on delivery_addresses');
select ok(has_table_privilege('authenticated', 'public.delivery_addresses', 'SELECT'), 'authenticated keeps SELECT');
select ok(not exists (select 1 from unnest(array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p where has_table_privilege('authenticated', 'public.delivery_addresses', p)), 'authenticated holds no write-type privilege');
select ok((select bool_and(has_table_privilege('service_role', 'public.delivery_addresses', p)) from unnest(array['SELECT','INSERT','UPDATE','DELETE']) p), 'service_role keeps its privileges');

-- Direct writes are closed for every kind of company member -------------------------------------------------------------------
select pg_temp.act_as(pg_temp.id('a1'));
set local role authenticated;
select throws_ok($$insert into public.delivery_addresses (company_id, label, street_address, city, state, pincode) values (pg_temp.id('co_a'), 'DIRECT', 'x', 'x', 'x', 'x')$$, '42501', NULL, 'approved buyer cannot insert directly');
select throws_ok($$update public.delivery_addresses set label = 'DIRECT' where id = pg_temp.id('seed')$$, '42501', NULL, 'approved buyer cannot update directly');
select throws_ok($$delete from public.delivery_addresses where id = pg_temp.id('seed')$$, '42501', NULL, 'approved buyer cannot delete directly');
select throws_ok($$truncate public.delivery_addresses$$, '42501', NULL, 'approved buyer cannot truncate');
select is((select count(*)::int from public.delivery_addresses), 1, 'reads are unchanged: the buyer still sees exactly its own company address');
reset role;
select pg_temp.act_as(pg_temp.id('ap'));
set local role authenticated;
select throws_ok($$insert into public.delivery_addresses (company_id, label, street_address, city, state, pincode) values (pg_temp.id('co_a'), 'DIRECT', 'x', 'x', 'x', 'x')$$, '42501', NULL, 'pending (unapproved) user cannot insert directly');
reset role;
select pg_temp.act_as(pg_temp.id('f1'));
set local role authenticated;
select throws_ok($$delete from public.delivery_addresses where company_id = pg_temp.id('co_f')$$, '42501', NULL, 'user of a frozen company cannot delete directly');
reset role;
select pg_temp.act_as(pg_temp.id('b1'));
set local role authenticated;
select is((select count(*)::int from public.delivery_addresses where company_id = pg_temp.id('co_a')), 0, 'another tenant still reads none of company A');
reset role;
set local role anon;
select throws_ok($$select count(*) from public.delivery_addresses$$, '42501', NULL, 'anon cannot read the table at all');
reset role;

-- The governed RPC workflows keep working --------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.id('a1'));
set local role authenticated;  -- exercise the real caller role, not the session owner
select is((select label from public.customer_upsert_delivery_address_v1(pg_temp.id('new'), 'Depot', '2 A Rd', 'Pune', 'MH', '411002', 'Ravi', '9999999999', false)), 'Depot', 'approved buyer can still create an address through the RPC');
select is((select count(*)::int from public.customer_delivery_addresses_v1()), 2, 'the list RPC returns the new address');
select is(public.customer_delete_delivery_address_v1(pg_temp.id('new')), true, 'approved buyer can still delete an address through the RPC');
select is((select transporter_name from public.customer_upsert_saved_transporter_v1(pg_temp.id('tr'), 'Safe Express', null, false, true)), 'Safe Express', 'saved-transporter RPC still works');
select pg_temp.act_as(pg_temp.id('ap'));
select throws_like($$select * from public.customer_upsert_delivery_address_v1(gen_random_uuid(), 'X', 'x', 'x', 'x', '1')$$, 'BUYER_ADDRESS_ELIGIBILITY_REQUIRED%', 'the RPC refuses the pending user the direct path used to admit');
select pg_temp.act_as(pg_temp.id('f1'));
select throws_like($$select * from public.customer_upsert_delivery_address_v1(gen_random_uuid(), 'X', 'x', 'x', 'x', '1')$$, 'BUYER_ADDRESS_ELIGIBILITY_REQUIRED%', 'the RPC refuses a user of a frozen company');
select pg_temp.act_as(pg_temp.id('a1'));
select throws_like($$select * from public.customer_upsert_delivery_address_v1(gen_random_uuid(), '  ', 'x', 'x', 'x', '1')$$, 'BUYER_ADDRESS_REQUIRED_FIELDS%', 'RPC validation can no longer be bypassed');
reset role;
select ok((select count(*) = 6 and bool_and(p.prosecdef and pg_get_userbyid(p.proowner) = pg_get_userbyid(c.relowner)) from pg_proc p, pg_class c where c.oid = 'public.delivery_addresses'::regclass and p.pronamespace = 'public'::regnamespace and p.proname in ('customer_delivery_addresses_v1','customer_upsert_delivery_address_v1','customer_delete_delivery_address_v1','customer_saved_transporters_v1','customer_upsert_saved_transporter_v1','customer_delete_saved_transporter_v1')), 'all six governed RPCs are SECURITY DEFINER and owned by the table owner');

select * from finish();
rollback;
