-- Contract test for 20261102090000_customer_order_draft_add_if_absent_v1.sql
-- Sequential semantics only (pgTAP runs in one transaction). Concurrent execution is covered by
-- docs/cart-insert-if-absent/README.md (24-way run evidence).
begin;

select plan(13);

select has_function('public', 'add_customer_order_draft_line_if_absent_v1', array['uuid', 'numeric'], 'add_customer_order_draft_line_if_absent_v1 exists');
select ok(not has_function_privilege('anon', 'public.add_customer_order_draft_line_if_absent_v1(uuid, numeric)', 'EXECUTE'), 'anon cannot execute the insert-if-absent RPC');
select ok(has_function_privilege('authenticated', 'public.add_customer_order_draft_line_if_absent_v1(uuid, numeric)', 'EXECUTE'), 'authenticated can execute the insert-if-absent RPC');

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
end $$;

-- helper: act as a user (sets both claim styles so it works on the Supabase image and on the local shim)
create or replace function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
end $$;

-- 1. first call inserts
select pg_temp.act_as((select v from _ids where k = 'a1'));
select is((select inserted from public.add_customer_order_draft_line_if_absent_v1((select v from _ids where k = 'p1'), 9)), true, 'first call inserts the line');

-- 2. retry with a different quantity must not overwrite
select is((select existing_quantity from public.add_customer_order_draft_line_if_absent_v1((select v from _ids where k = 'p1'), 18)), 9::numeric, 'retry with a different quantity reports the existing quantity');
select is((select quantity from public.customer_order_draft_lines l join public.customer_order_drafts d on d.id = l.draft_id where d.company_id = (select v from _ids where k = 'co_a') and l.product_id = (select v from _ids where k = 'p1')), 9::numeric, 'stored quantity unchanged by the retry');

-- 3. stale read: another user of the same company added 27 after this caller last read the cart
select pg_temp.act_as((select v from _ids where k = 'a2'));
select count(*) from public.add_customer_order_draft_line_v1((select v from _ids where k = 'p2'), 27);
select pg_temp.act_as((select v from _ids where k = 'a1'));
select is((select inserted from public.add_customer_order_draft_line_if_absent_v1((select v from _ids where k = 'p2'), 9)), false, 'stale read: insert-if-absent reports already present');
select is((select quantity from public.customer_order_draft_lines l join public.customer_order_drafts d on d.id = l.draft_id where d.company_id = (select v from _ids where k = 'co_a') and l.product_id = (select v from _ids where k = 'p2')), 27::numeric, 'stale read: the newer quantity 27 is not overwritten');

-- 4. tenant isolation
select pg_temp.act_as((select v from _ids where k = 'b'));
select is((select inserted from public.add_customer_order_draft_line_if_absent_v1((select v from _ids where k = 'p1'), 9)), true, 'other tenant gets its own line for the same product');
select is((select quantity from public.customer_order_draft_lines l join public.customer_order_drafts d on d.id = l.draft_id where d.company_id = (select v from _ids where k = 'co_a') and l.product_id = (select v from _ids where k = 'p1')), 9::numeric, 'tenant A line unaffected by tenant B call');

-- 5. gates
select pg_temp.act_as((select v from _ids where k = 'a1'));
select throws_like($$select * from public.add_customer_order_draft_line_if_absent_v1((select v from _ids where k = 'p1'), 10)$$, 'QUANTITY_RULE_VIOLATION%', 'MOQ/increment violation rejected');
select pg_temp.act_as((select v from _ids where k = 'staff'));
select throws_like($$select * from public.add_customer_order_draft_line_if_absent_v1((select v from _ids where k = 'p1'), 9)$$, 'BUYER_NOT_ELIGIBLE%', 'non-buyer rejected');
select pg_temp.act_as(null);
select throws_like($$select * from public.add_customer_order_draft_line_if_absent_v1((select v from _ids where k = 'p1'), 9)$$, 'AUTH_REQUIRED%', 'unauthenticated rejected');

select * from finish();
rollback;
