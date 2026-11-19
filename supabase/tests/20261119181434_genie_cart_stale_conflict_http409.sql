-- Regression for 20261119181434_genie_cart_stale_conflict_http409.sql.
-- Covers PT409 transport classification, canonical success, unchanged data on
-- rejection, legacy Cart edits, and caller authorization in a rolled-back fixture.
begin;
select plan(17);

create temp table _genie_ids(k text primary key, v uuid);
grant all on _genie_ids to public;

do $$
declare
  a uuid; b uuid;
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  b1 uuid := gen_random_uuid(); staff uuid := gen_random_uuid();
  prod1 uuid; prod2 uuid;
begin
  set local session_replication_role = replica;
  insert into public.companies(business_name, status) values ('GenieOp A','active') returning id into a;
  insert into public.companies(business_name, status) values ('GenieOp B','active') returning id into b;
  insert into auth.users(id,email) values
    (a1,'genie-op-a1@example.com'),(a2,'genie-op-a2@example.com'),
    (b1,'genie-op-b@example.com'),(staff,'genie-op-staff@example.com');
  insert into public.profiles(id,company_id,role,is_approved,status,email) values
    (a1,a,'b2b_buyer',true,'approved','genie-op-a1@example.com'),
    (a2,a,'b2b_buyer',true,'approved','genie-op-a2@example.com'),
    (b1,b,'b2b_buyer',true,'approved','genie-op-b@example.com'),
    (staff,null,'admin',true,'approved','genie-op-staff@example.com');
  insert into public.products(sku,product_name,name,category,hsn_code,is_active,visible_in_catalog,is_catalogue_ready,moq_value,increment_value,base_price)
  values ('GENIE-OP-1','Genie Op 1','Genie Op 1','Bakery','19059090',true,true,true,9,9,650) returning id into prod1;
  insert into public.products(sku,product_name,name,category,hsn_code,is_active,visible_in_catalog,is_catalogue_ready,moq_value,increment_value,base_price)
  values ('GENIE-OP-2','Genie Op 2','Genie Op 2','Bakery','19059090',true,true,true,9,9,650) returning id into prod2;
  insert into public.product_pricing_rules(product_id,price_channel,approval_status,base_price,calculated_price,currency,uom,gst_rate,tax_inclusive)
  select id,'b2b','approved',650,650,'INR','kg',0,true from public.products where sku in ('GENIE-OP-1','GENIE-OP-2');
  insert into public.product_moq_rules(product_id,channel,moq_applicable,moq_value,increment_value,min_carton_qty)
  select id,'b2b',true,9,9,9 from public.products where sku in ('GENIE-OP-1','GENIE-OP-2');
  insert into _genie_ids values
    ('a',a),('b',b),('a1',a1),('a2',a2),('b1',b1),('staff',staff),
    ('p1',prod1),('p2',prod2),('op1',gen_random_uuid()),
    ('op2',gen_random_uuid()),('op3',gen_random_uuid());
  set local session_replication_role = origin;
end $$;
create or replace function pg_temp.genie_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid::text,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
end $$;

select has_function('public','update_customer_order_draft_line_genie_if_quantity_v1',array['uuid','uuid','numeric','numeric'],'Genie CAS RPC exists');

select ok(not has_function_privilege('anon','public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric)','EXECUTE'),'anon cannot execute compare-and-swap');

select ok(has_function_privilege('authenticated','public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric)','EXECUTE'),'authenticated buyers may execute compare-and-swap');

select ok((select position('pg_advisory_xact_lock' in p.prosrc) > 0 and position('pg_advisory_xact_lock' in p.prosrc) < position('for update of l' in p.prosrc) and p.prosecdef from pg_proc p where p.oid='public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric)'::regprocedure),'per-company lock precedes row lock and security definer retained');

select pg_temp.genie_as((select v from _genie_ids where k='a1'));

select count(*) from public.add_customer_order_draft_line_v1((select v from _genie_ids where k='p1'),9);

select is((select count(*)::int from public.update_customer_order_draft_line_genie_if_quantity_v1((select id from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') and quantity=9 limit 1),(select v from _genie_ids where k='p1'),9,18)),1,'CAS 9 to 18 succeeds with correct expected quantity');

select is((select quantity from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),18::numeric,'CAS update persists expected quantity');

select throws_ok($select * from public.update_customer_order_draft_line_genie_if_quantity_v1((select id from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),(select v from _genie_ids where k='p1'),9,27)$,'PT409','GENIE_CART_STALE: product or quantity changed; reconcile in Cart','stale quantity returns a permanent HTTP 409 conflict');

select throws_ok($select * from public.update_customer_order_draft_line_genie_if_quantity_v1((select id from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),(select v from _genie_ids where k='p2'),18,27)$,'PT409','GENIE_CART_STALE: product or quantity changed; reconcile in Cart','wrong product returns a permanent HTTP 409 conflict');

select throws_like($$select * from public.update_customer_order_draft_line_genie_if_quantity_v1((select id from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),(select v from _genie_ids where k='p1'),18,0)$$,'VALIDATION_FAILED%','invalid new quantity rejected');

select is((select quantity from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),18::numeric,'rejected CAS calls do not modify quantity');

select count(*) from public.update_customer_order_draft_line_v1((select id from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),27);

select throws_like($$select * from public.update_customer_order_draft_line_genie_if_quantity_v1((select id from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),(select v from _genie_ids where k='p1'),18,36)$$,'GENIE_CART_STALE%','intervening ordinary Cart writer prevents Genie stale overwrite');

select is((select quantity from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),27::numeric,'concurrent-style Cart edit preserved after stale CAS rejection');

select is((select count(*)::int from public.update_customer_order_draft_line_genie_if_quantity_v1((select id from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),(select v from _genie_ids where k='p1'),27,36)),1,'CAS succeeds when expected value refreshed to current Cart quantity');

select pg_temp.genie_as((select v from _genie_ids where k='b1'));

select throws_like($$select * from public.update_customer_order_draft_line_genie_if_quantity_v1((select id from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),(select v from _genie_ids where k='p1'),36,45)$$,'LINE_NOT_FOUND%','another tenant cannot update Cart line');

select pg_temp.genie_as((select v from _genie_ids where k='staff'));

select throws_like($$select * from public.update_customer_order_draft_line_genie_if_quantity_v1((select id from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),(select v from _genie_ids where k='p1'),36,45)$$,'BUYER_NOT_ELIGIBLE%','staff cannot mutate protected buyer Cart');

select pg_temp.genie_as((select v from _genie_ids where k='a1'));

update public.profiles set is_approved=false where id=(select v from _genie_ids where k='a1');

select throws_like($$select * from public.update_customer_order_draft_line_genie_if_quantity_v1((select id from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p1') limit 1),(select v from _genie_ids where k='p1'),36,45)$$,'BUYER_NOT_ELIGIBLE%','revoked buyer cannot CAS update');

select pg_temp.genie_as(null);

select throws_like($$select * from public.update_customer_order_draft_line_genie_if_quantity_v1(gen_random_uuid(),gen_random_uuid(),9,18)$$,'AUTH_REQUIRED%','unauthenticated callers rejected');

select * from finish();
rollback;
