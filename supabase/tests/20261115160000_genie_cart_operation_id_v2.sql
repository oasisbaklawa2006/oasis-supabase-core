-- Contract test for 20261115160000_genie_cart_operation_id_v2.sql (Core #535).
-- pgTAP operates inside a rollback-only transaction. Parallel PostgREST and device tests remain required.
begin;

select plan(29);

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

select has_function('public','add_customer_order_draft_line_genie_v2',array['uuid','numeric','uuid'],'v2 RPC exists');

select ok(not has_function_privilege('anon','public.add_customer_order_draft_line_genie_v2(uuid,numeric,uuid)','EXECUTE'),'anon cannot call operation RPC');

select ok(has_function_privilege('authenticated','public.add_customer_order_draft_line_genie_v2(uuid,numeric,uuid)','EXECUTE'),'authenticated buyer can call operation RPC');

select ok(not has_table_privilege('authenticated','public.customer_genie_cart_operations','SELECT'),'authenticated cannot read operation receipts directly');

select ok(not has_table_privilege('authenticated','public.customer_genie_cart_operations','INSERT'),'authenticated cannot create forged receipts');

select pg_temp.genie_as((select v from _genie_ids where k='a1'));

select is((select inserted from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,(select v from _genie_ids where k='op1'))),true,'first call inserts');

select is((select count(*)::int from public.customer_genie_cart_operations),1,'insert and operation receipt both persisted');

select is((select replayed from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,(select v from _genie_ids where k='op1'))),true,'lost-response retry returns receipt');

select is((select line_id from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,(select v from _genie_ids where k='op1'))),(select draft_line_id from public.customer_genie_cart_operations where operation_id=(select v from _genie_ids where k='op1')),'retry returns original authoritative line ID');

select is((select count(*)::int from public.customer_order_draft_lines),1,'replayed request does not duplicate Cart line');

select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),18,(select v from _genie_ids where k='op1'))$$,'GENIE_OPERATION_MISMATCH%','reuse with changed quantity rejected');

select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p2'),9,(select v from _genie_ids where k='op1'))$$,'GENIE_OPERATION_MISMATCH%','reuse with changed product rejected');

select pg_temp.genie_as((select v from _genie_ids where k='a2'));

select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,(select v from _genie_ids where k='op1'))$$,'GENIE_OPERATION_MISMATCH%','same company other buyer cannot replay operation');

select pg_temp.genie_as((select v from _genie_ids where k='b1'));

select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,(select v from _genie_ids where k='op1'))$$,'GENIE_OPERATION_MISMATCH%','other tenant cannot replay operation');

select pg_temp.genie_as((select v from _genie_ids where k='a1'));

select count(*) from public.add_customer_order_draft_line_v1((select v from _genie_ids where k='p2'),27);

select is((select inserted from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p2'),9,(select v from _genie_ids where k='op2'))),false,'existing manual Cart line is NOT adopted');

select is((select quantity from public.customer_order_draft_lines where product_id=(select v from _genie_ids where k='p2')),27::numeric,'manual Cart quantity is preserved');

select is((select inserted from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p2'),9,(select v from _genie_ids where k='op2'))),false,'replayed existing-line result stays false');

select is((select replayed from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p2'),9,(select v from _genie_ids where k='op2'))),true,'replay of conflict receipt is explicit');
select is((select existing_quantity from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p2'),9,(select v from _genie_ids where k='op2'))),27::numeric,'conflict replay returns authoritative original Cart quantity');
-- A conflicting manual Cart line is not Genie-owned: if its server state changes,
-- the old receipt must fail closed rather than returning a stale quantity or ID.
select count(*) from public.update_customer_order_draft_line_v1(
  (select draft_line_id from public.customer_genie_cart_operations where operation_id=(select v from _genie_ids where k='op2')), 54
);
select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p2'),9,(select v from _genie_ids where k='op2'))$$,'GENIE_OPERATION_STALE%','changed manual Cart line invalidates conflict replay');
select count(*) from public.remove_customer_order_draft_line_v1(
  (select draft_line_id from public.customer_genie_cart_operations where operation_id=(select v from _genie_ids where k='op2'))
);
select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p2'),9,(select v from _genie_ids where k='op2'))$$,'GENIE_OPERATION_STALE%','deleted manual Cart line invalidates conflict replay');


select pg_temp.genie_as((select v from _genie_ids where k='b1'));

select is((select inserted from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,(select v from _genie_ids where k='op3'))),true,'independent tenant and operation insert succeeds');

select pg_temp.genie_as((select v from _genie_ids where k='staff'));

select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,gen_random_uuid())$$,'BUYER_NOT_ELIGIBLE%','staff cannot mutate buyer Cart');

select pg_temp.genie_as(null);

select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,gen_random_uuid())$$,'AUTH_REQUIRED%','anonymous cannot mutate Cart');

select pg_temp.genie_as((select v from _genie_ids where k='a1'));

select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,null)$$,'VALIDATION_FAILED%','missing operation ID rejected');

select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),0,gen_random_uuid())$$,'VALIDATION_FAILED%','invalid quantity rejected');

-- A revoked former buyer cannot replay a prior successful operation receipt.
update public.profiles set is_approved = false where id = (select v from _genie_ids where k='a1');
select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,(select v from _genie_ids where k='op1'))$$,'BUYER_NOT_ELIGIBLE%','revoked buyer cannot replay a committed Genie operation');
update public.profiles set is_approved = true where id = (select v from _genie_ids where k='a1');

select count(*) from public.remove_customer_order_draft_line_v1((select draft_line_id from public.customer_genie_cart_operations where operation_id=(select v from _genie_ids where k='op1')));

select throws_like($$select * from public.add_customer_order_draft_line_genie_v2((select v from _genie_ids where k='p1'),9,(select v from _genie_ids where k='op1'))$$,'GENIE_OPERATION_STALE%','deleted Cart line cannot be falsely replayed as present');

select is((select count(*)::int from public.customer_genie_cart_operations),3,'failed mismatched operations do not persist any receipts');

select * from finish();
rollback;
