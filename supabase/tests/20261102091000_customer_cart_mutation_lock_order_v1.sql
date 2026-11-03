-- Contract test for 20261102091000_customer_cart_mutation_lock_order_v1.sql
-- Sequential semantics only (pgTAP runs in one transaction). The deadlock behaviour itself is covered by the concurrency evidence in
-- docs/cart-insert-if-absent/README.md (24-client mixed workload: 0 deadlocks after, ~7-10% before).
begin;

select plan(16);


create temp table _ids (k text primary key, v uuid);
grant all on _ids to public;

do $$
declare
  v_co_a uuid; v_co_b uuid;
  v_a1 uuid := gen_random_uuid(); v_a2 uuid := gen_random_uuid(); v_b uuid := gen_random_uuid(); v_staff uuid := gen_random_uuid();
  v_p uuid; v_p2 uuid;
begin
  set local session_replication_role = replica;
  insert into public.companies (business_name, status) values ('IfAbsent Co A', 'active') returning id into v_co_a;
  insert into public.companies (business_name, status) values ('IfAbsent Co B', 'active') returning id into v_co_b;
  insert into auth.users (id, email) values (v_a1, 'ia-a1@example.com'), (v_a2, 'ia-a2@example.com'), (v_b, 'ia-b@example.com'), (v_staff, 'ia-staff@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email) values
    (v_a1, v_co_a, 'b2b_buyer', true, 'approved', 'ia-a1@example.com'),
    (v_a2, v_co_a, 'b2b_buyer', true, 'approved', 'ia-a2@example.com'),
    (v_b, v_co_b, 'b2b_buyer', true, 'approved', 'ia-b@example.com'),
    (v_staff, null, 'admin', true, 'approved', 'ia-staff@example.com');
  insert into public.products (sku, product_name, name, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price)
  values ('IA-SKU-1', 'IfAbsent One', 'IfAbsent One', 'Bakery', '19059090', true, true, true, 9, 9, 650) returning id into v_p;
  insert into public.products (sku, product_name, name, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price)
  values ('IA-SKU-2', 'IfAbsent Two', 'IfAbsent Two', 'Bakery', '19059090', true, true, true, 9, 9, 650) returning id into v_p2;
  insert into public.product_pricing_rules (product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive)
  select id, 'b2b', 'approved', 650, 650, 'INR', 'kg', 0, true from public.products where sku in ('IA-SKU-1', 'IA-SKU-2');
  insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  select id, 'b2b', true, 9, 9, 9 from public.products where sku in ('IA-SKU-1', 'IA-SKU-2');
  insert into _ids values ('co_a', v_co_a), ('co_b', v_co_b), ('a1', v_a1), ('a2', v_a2), ('b', v_b), ('staff', v_staff), ('p1', v_p), ('p2', v_p2);
  set local session_replication_role = origin; -- fixture setup only: RPC assertions below run with FK checks enforced
end $$;

-- helper: act as a user (sets both claim styles so it works on the Supabase image and on the local shim)
create or replace function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
end $$;

-- Definition-level contract -----------------------------------------------------------------------------------------------
select ok((select count(*) = 2 and bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=pg_catalog, public, auth%')
           from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('remove_customer_order_draft_line_v1', 'update_customer_order_draft_line_v1')),
          'remove/update stay SECURITY DEFINER with the unchanged pinned search_path');
select ok((select count(*) = 2 and bool_and(position('pg_advisory_xact_lock' in p.prosrc) > 0 and position('pg_advisory_xact_lock' in p.prosrc) < position('for update of l' in p.prosrc))
           from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('remove_customer_order_draft_line_v1', 'update_customer_order_draft_line_v1')),
          'remove/update take the company advisory lock before they lock the line row');
select ok((select count(*) = 5 and bool_and(position('hashtextextended(''customer_draft:'' || v_company_id::text, 0)' in p.prosrc) > 0)
           from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('remove_customer_order_draft_line_v1', 'update_customer_order_draft_line_v1', 'add_customer_order_draft_line_v1', 'add_customer_order_draft_line_if_absent_v1', 'clear_customer_order_draft_v1')),
          'all five cart mutations use the same per-company advisory lock key');
select ok(not has_function_privilege('anon', 'public.remove_customer_order_draft_line_v1(uuid)', 'EXECUTE') and not has_function_privilege('anon', 'public.update_customer_order_draft_line_v1(uuid, numeric)', 'EXECUTE'), 'anon cannot execute remove/update');
select ok(has_function_privilege('authenticated', 'public.remove_customer_order_draft_line_v1(uuid)', 'EXECUTE') and has_function_privilege('authenticated', 'public.update_customer_order_draft_line_v1(uuid, numeric)', 'EXECUTE'), 'authenticated can execute remove/update');

-- helper: act as a user
create or replace function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
end $$;

-- Behaviour is unchanged: quantities, price snapshots, readiness and audit ----------------------------------------------------
select pg_temp.act_as((select v from _ids where k = 'a1'));
create temp table _l (k text primary key, v uuid, price numeric, qty numeric); grant all on _l to public;
insert into _l select 'line', line_id, null, null from public.add_customer_order_draft_line_v1((select v from _ids where k = 'p1'), 9);
update _l set price = (select unit_price_snapshot from public.customer_order_draft_lines where id = (select v from _l where k = 'line'));
select is((select quantity from public.customer_order_draft_lines where id = (select v from _l where k = 'line')), 9::numeric, 'baseline: the line starts at the MOQ quantity');
select is((select line_id from public.update_customer_order_draft_line_v1((select v from _l where k = 'line'), 18)), (select v from _l where k = 'line'), 'update returns the same line');
select is((select quantity from public.customer_order_draft_lines where id = (select v from _l where k = 'line')), 18::numeric, 'update changes only the quantity');
select is((select unit_price_snapshot from public.customer_order_draft_lines where id = (select v from _l where k = 'line')), (select price from _l where k = 'line'), 'update leaves the server-resolved unit price unchanged');
select throws_like($$select * from public.update_customer_order_draft_line_v1((select v from _l where k = 'line'), 10)$$, 'QUANTITY_RULE_VIOLATION%', 'increment violation is still rejected');
select is((select quantity from public.customer_order_draft_lines where id = (select v from _l where k = 'line')), 18::numeric, 'a rejected update leaves the stored quantity unchanged');
select throws_like($$select * from public.update_customer_order_draft_line_v1((select v from _l where k = 'line'), 0)$$, 'VALIDATION_FAILED%', 'non-positive quantity is still rejected');

-- Tenant isolation and gates -----------------------------------------------------------------------------------------------------
select pg_temp.act_as((select v from _ids where k = 'b'));
select throws_ok($$select * from public.update_customer_order_draft_line_v1((select v from _l where k = 'line'), 9)$$, 'P0002', NULL, 'another tenant cannot update the line');
select throws_ok($$select * from public.remove_customer_order_draft_line_v1((select v from _l where k = 'line'))$$, 'P0002', NULL, 'another tenant cannot remove the line');
select pg_temp.act_as(null);
select throws_like($$select * from public.remove_customer_order_draft_line_v1((select v from _l where k = 'line'))$$, 'AUTH_REQUIRED%', 'unauthenticated callers are rejected');

-- Removal still works and a rolled-back call restores state ---------------------------------------------------------------------
select pg_temp.act_as((select v from _ids where k = 'a1'));
select count(*) from public.remove_customer_order_draft_line_v1((select v from _l where k = 'line'));
select is((select count(*)::int from public.customer_order_draft_lines where id = (select v from _l where k = 'line')), 0, 'owner can still remove the line');

select * from finish();
rollback;
