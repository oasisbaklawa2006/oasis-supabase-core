-- Contract test for 20261109104000_buyer_delivery_address_and_saved_transporter_authority_v1.sql
begin;

select plan(40);

select has_function('public', 'customer_upsert_delivery_address_v1', array['uuid','text','text','text','text','text','text','text','boolean'], 'address upsert exists');
select has_function('public', 'customer_delete_delivery_address_v1', array['uuid'], 'address delete exists');
select has_function('public', 'customer_saved_transporters_v1', array[]::text[], 'transporter list exists');
select has_function('public', 'customer_upsert_saved_transporter_v1', array['uuid','text','text','boolean','boolean'], 'transporter upsert exists');
select has_function('public', 'customer_delete_saved_transporter_v1', array['uuid'], 'transporter delete exists');
select ok(not has_function_privilege('anon', 'public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)', 'EXECUTE'), 'anon cannot upsert addresses');
select ok(not has_function_privilege('anon', 'public.customer_upsert_saved_transporter_v1(uuid,text,text,boolean,boolean)', 'EXECUTE'), 'anon cannot upsert transporters');
select ok(has_function_privilege('authenticated', 'public.customer_saved_transporters_v1()', 'EXECUTE'), 'authenticated can list transporters');
select ok(not has_table_privilege('authenticated', 'public.customer_saved_transporters', 'INSERT') and not has_table_privilege('authenticated', 'public.customer_saved_transporters', 'SELECT'), 'authenticated has no direct table access to saved transporters');
select ok((select relrowsecurity from pg_class where oid = 'public.customer_saved_transporters'::regclass), 'RLS enabled on saved transporters');
select ok(exists(select 1 from pg_indexes where schemaname = 'public' and indexname = 'customer_saved_transporters_one_default_per_company'), 'one-default-per-company unique index exists');
select is((select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'customer_saved_transporters' and column_name = 'created_by'), 'YES', 'created_by is nullable (audit hint, not ownership)');
select ok(exists(select 1 from pg_constraint where conrelid = 'public.customer_saved_transporters'::regclass and contype = 'f' and confrelid = 'auth.users'::regclass and confdeltype = 'n'), 'deleting the creating auth user sets created_by to NULL instead of blocking account deletion');

create temp table _ids (k text primary key, v uuid);
grant all on _ids to public;
do $$
declare v_a uuid; v_b uuid; v_a1 uuid := gen_random_uuid(); v_a2 uuid := gen_random_uuid(); v_b1 uuid := gen_random_uuid(); v_st uuid := gen_random_uuid();
begin
  set local session_replication_role = replica;
  insert into public.companies (business_name, status) values ('AddrTrans Co A', 'active') returning id into v_a;
  insert into public.companies (business_name, status) values ('AddrTrans Co B', 'active') returning id into v_b;
  insert into auth.users (id, email) values (v_a1,'at-a1@example.com'),(v_a2,'at-a2@example.com'),(v_b1,'at-b1@example.com'),(v_st,'at-st@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email) values
    (v_a1, v_a, 'b2b_buyer', true, 'approved', 'at-a1@example.com'),
    (v_a2, v_a, 'b2b_buyer', true, 'approved', 'at-a2@example.com'),
    (v_b1, v_b, 'b2b_buyer', true, 'approved', 'at-b1@example.com'),
    (v_st, null, 'admin', true, 'approved', 'at-st@example.com');
  insert into _ids values ('co_a', v_a), ('co_b', v_b), ('a1', v_a1), ('a2', v_a2), ('b1', v_b1), ('st', v_st),
    ('addr1', gen_random_uuid()), ('addr2', gen_random_uuid()), ('tr1', gen_random_uuid()), ('tr2', gen_random_uuid()), ('trb', gen_random_uuid());
  set local session_replication_role = origin; -- fixture setup only: RPC assertions below run with FK checks enforced
end $$;

create or replace function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
end $$;
create or replace function pg_temp.id(p text) returns uuid language sql as $$ select v from _ids where k = p $$;

-- ADDRESSES
select pg_temp.act_as(pg_temp.id('a1'));
select is((select label from public.customer_upsert_delivery_address_v1(pg_temp.id('addr1'), 'HQ', '1 Main Rd', 'Pune', 'MH', '411001', 'Ravi', '9999999999', true)), 'HQ', 'address inserted');
select is((select company_id from public.delivery_addresses where id = pg_temp.id('addr1')), pg_temp.id('co_a'), 'address stored under the caller company');
select throws_like($$select * from public.customer_upsert_delivery_address_v1(pg_temp.id('addr2'), '  ', '1 Main Rd', 'Pune', 'MH', '411001')$$, 'BUYER_ADDRESS_REQUIRED_FIELDS%', 'blank label rejected');
select throws_like($$select * from public.customer_upsert_delivery_address_v1(pg_temp.id('addr2'), repeat('x', 81), '1 Main Rd', 'Pune', 'MH', '411001')$$, 'BUYER_ADDRESS_FIELD_TOO_LONG%', 'over-long label rejected');
select throws_like($$select * from public.customer_upsert_delivery_address_v1(pg_temp.id('addr2'), 'Bad' || chr(7), '1 Main Rd', 'Pune', 'MH', '411001')$$, 'BUYER_ADDRESS_CONTROL_CHAR_FORBIDDEN%', 'control characters rejected');
select pg_temp.act_as(pg_temp.id('a2'));
select lives_ok($$select * from public.customer_upsert_delivery_address_v1(pg_temp.id('addr2'), 'Depot', '2 Side St', 'Mumbai', 'MH', '400001', null, null, true)$$, 'second user of the same company adds a default address');
select is((select count(*)::int from public.delivery_addresses where company_id = pg_temp.id('co_a') and is_default), 1, 'exactly one default address after switching');
select is((select is_default from public.delivery_addresses where id = pg_temp.id('addr1')), false, 'previous default cleared');
-- tenant isolation
select pg_temp.act_as(pg_temp.id('b1'));
select throws_like($$select * from public.customer_upsert_delivery_address_v1(pg_temp.id('addr1'), 'HIJACK', 'x', 'x', 'x', '1')$$, 'BUYER_ADDRESS_SCOPE_REQUIRED%', 'other tenant cannot overwrite an address by id');
select is((select label from public.delivery_addresses where id = pg_temp.id('addr1')), 'HQ', 'tenant A address unchanged');
select throws_like($$select public.customer_delete_delivery_address_v1(pg_temp.id('addr1'))$$, 'BUYER_ADDRESS_NOT_FOUND%', 'other tenant cannot delete an address');
select is((select count(*)::int from public.customer_delivery_addresses_v1()), 0, 'tenant B reads none of tenant A addresses');
-- delete default promotes another
select pg_temp.act_as(pg_temp.id('a1'));
select is(public.customer_delete_delivery_address_v1(pg_temp.id('addr2')), true, 'default address deleted');
select is((select is_default from public.delivery_addresses where id = pg_temp.id('addr1')), true, 'remaining address becomes default');
-- gates
select pg_temp.act_as(pg_temp.id('st'));
select throws_like($$select * from public.customer_upsert_delivery_address_v1(pg_temp.id('addr2'), 'S', 's', 's', 's', '1')$$, 'BUYER_ADDRESS_ELIGIBILITY_REQUIRED%', 'non-buyer rejected');

-- TRANSPORTERS
select pg_temp.act_as(pg_temp.id('a1'));
select is((select transporter_name from public.customer_upsert_saved_transporter_v1(pg_temp.id('tr1'), 'VRL Logistics', 'AC-1', true, true)), 'VRL Logistics', 'transporter inserted');
select is((select preferred_courier from public.companies where id = pg_temp.id('co_a')), 'VRL Logistics', 'legacy preferred_courier mirrors the default');
select lives_ok($$select * from public.customer_upsert_saved_transporter_v1(pg_temp.id('tr2'), 'Gati', null, true, true)$$, 'second default transporter');
select is((select count(*)::int from public.customer_saved_transporters where company_id = pg_temp.id('co_a') and is_default), 1, 'exactly one default transporter');
select is((select is_default from public.customer_saved_transporters where id = pg_temp.id('tr1')), false, 'previous default transporter cleared');
select is((select is_default from public.customer_upsert_saved_transporter_v1(pg_temp.id('tr2'), 'Gati', null, true, false)), false, 'inactive transporter can never be default');
select throws_like($$select * from public.customer_upsert_saved_transporter_v1(pg_temp.id('tr1'), '', null)$$, 'BUYER_TRANSPORTER_REQUIRED_FIELDS%', 'blank transporter name rejected');
select throws_like($$select * from public.customer_upsert_saved_transporter_v1(pg_temp.id('tr1'), repeat('y', 121))$$, 'BUYER_TRANSPORTER_FIELD_TOO_LONG%', 'over-long transporter name rejected');
select pg_temp.act_as(pg_temp.id('b1'));
select throws_like($$select * from public.customer_upsert_saved_transporter_v1(pg_temp.id('tr1'), 'HIJACK')$$, 'BUYER_TRANSPORTER_SCOPE_REQUIRED%', 'other tenant cannot overwrite a transporter by id');
select throws_like($$select public.customer_delete_saved_transporter_v1(pg_temp.id('tr1'))$$, 'BUYER_TRANSPORTER_NOT_FOUND%', 'other tenant cannot delete a transporter');
select is((select count(*)::int from public.customer_saved_transporters_v1()), 0, 'tenant B lists none of tenant A transporters');
select pg_temp.act_as(pg_temp.id('a1'));
select is(public.customer_delete_saved_transporter_v1(pg_temp.id('tr1')), true, 'transporter deleted');

select * from finish();
rollback;
