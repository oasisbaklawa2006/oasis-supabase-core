-- Disposable #519 Preview stkvyotdkysieuvpuues ONLY. Run through the pinned
-- management target after the 39-function quarantine and quiet-DB checks.
-- Real deployed schema/RPCs and real SQL roles; NOT GoTrue, device or provider UAT.
-- No trigger disabling, replication-role change, migration, or committed fixture.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '40s';
create temp table cert519_results(label text primary key, passed boolean not null);
create temp table cert519_ids(label text primary key,id uuid not null);
grant all on cert519_results,cert519_ids to authenticated;
create function pg_temp.cert519_check(value boolean,label text) returns void language plpgsql as $$
begin
  if value is distinct from true then raise exception 'CORE519_PROBE_FAILED: %',label; end if;
  insert into cert519_results values(label,true);
end $$;
create function pg_temp.cert519_id(label text) returns uuid language sql as $$ select id from cert519_ids where cert519_ids.label=$1 $$;
create function pg_temp.cert519_act(label text) returns void language plpgsql as $$
declare uid uuid:=pg_temp.cert519_id(label);
begin
  perform set_config('request.jwt.claim.sub',uid::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',uid,'role','authenticated')::text,true);
end $$;
create function pg_temp.cert519_denied(statement text,prefix text,label text) returns void language plpgsql as $$
declare denied boolean:=false;
begin
  begin execute statement;
  exception when others then
    if sqlerrm not like prefix||'%' then raise; end if;
    denied:=true;
  end;
  perform pg_temp.cert519_check(denied,label);
end $$;
grant execute on function pg_temp.cert519_check(boolean,text),pg_temp.cert519_id(text),pg_temp.cert519_act(text),pg_temp.cert519_denied(text,text,text) to authenticated;

-- Every fixture and every downstream wallet/audit effect is rolled back together.
insert into cert519_ids select label,gen_random_uuid() from unnest(array['co_a','co_b','co_f','a1','a2','b1','pending','frozen','staff','ad1','ad2','private','tr1','tr2']) label;
insert into public.companies(id,business_name,status,is_frozen) values
  (pg_temp.cert519_id('co_a'),'__CERT_CORE519_A','active',false),
  (pg_temp.cert519_id('co_b'),'__CERT_CORE519_B','active',false),
  (pg_temp.cert519_id('co_f'),'__CERT_CORE519_FROZEN','active',true);
insert into auth.users(id,email) select id,label||'@core519-cert.invalid' from cert519_ids where label in ('a1','a2','b1','pending','frozen','staff');
insert into public.profiles(id,company_id,role,is_approved,status,email) values
  (pg_temp.cert519_id('a1'),pg_temp.cert519_id('co_a'),'b2b_buyer',true,'approved','a1@core519-cert.invalid'),
  (pg_temp.cert519_id('a2'),pg_temp.cert519_id('co_a'),'b2b_buyer',true,'approved','a2@core519-cert.invalid'),
  (pg_temp.cert519_id('b1'),pg_temp.cert519_id('co_b'),'b2b_buyer',true,'approved','b1@core519-cert.invalid'),
  (pg_temp.cert519_id('pending'),pg_temp.cert519_id('co_a'),'b2b_buyer',false,'pending','pending@core519-cert.invalid'),
  (pg_temp.cert519_id('frozen'),pg_temp.cert519_id('co_f'),'b2b_buyer',true,'approved','frozen@core519-cert.invalid'),
  (pg_temp.cert519_id('staff'),null,'admin',true,'approved','staff@core519-cert.invalid');

select pg_temp.cert519_act('a1');
set local role authenticated;
select pg_temp.cert519_check(public.customer_buyer_eligible_company_id()=pg_temp.cert519_id('co_a'),'approved eligibility');
select pg_temp.cert519_check((select label='Warehouse' from public.customer_upsert_delivery_address_v1(pg_temp.cert519_id('ad1'),'Warehouse','1 Synthetic Road','Delhi','DL','110001',null,null,true)),'address create');
select pg_temp.cert519_check((select count(*)=1 from public.customer_delivery_addresses_v1()),'address list');
select pg_temp.cert519_check((select label='Warehouse Edited' from public.customer_upsert_delivery_address_v1(pg_temp.cert519_id('ad1'),'Warehouse Edited','2 Synthetic Road','Delhi','DL','110001',null,null,true)),'address edit');
select pg_temp.cert519_check((select label='Depot' from public.customer_upsert_delivery_address_v1(pg_temp.cert519_id('ad2'),'Depot','3 Synthetic Road','Delhi','DL','110001',null,null,true)),'second address create/default');
select pg_temp.cert519_check((select count(*)=1 from public.customer_delivery_addresses_v1() where is_default),'one visible address default');
select pg_temp.cert519_check((select transporter_name='Synthetic Carrier' from public.customer_upsert_saved_transporter_v1(pg_temp.cert519_id('tr1'),'Synthetic Carrier','SYN-1',true,true)),'transporter create');
select pg_temp.cert519_check((select count(*)=1 from public.customer_saved_transporters_v1()),'transporter list');
select pg_temp.cert519_check((select transporter_name='Synthetic Carrier Edited' from public.customer_upsert_saved_transporter_v1(pg_temp.cert519_id('tr1'),'Synthetic Carrier Edited','SYN-2',true,true)),'transporter edit');
select pg_temp.cert519_check((select is_default from public.customer_upsert_saved_transporter_v1(pg_temp.cert519_id('tr2'),'Second Synthetic Carrier',null,true,true)),'transporter switch default');
select pg_temp.cert519_check((select count(*)=1 from public.customer_saved_transporters_v1() where is_default),'one transporter default');
select pg_temp.cert519_denied($q$insert into public.delivery_addresses(company_id,label,street_address,city,state,pincode) values(pg_temp.cert519_id('co_a'),'DIRECT','x','x','x','x')$q$,'permission denied','direct address insert denied');
select pg_temp.cert519_denied($q$update public.delivery_addresses set label='DIRECT' where id=pg_temp.cert519_id('ad1')$q$,'permission denied','direct address update denied');
select pg_temp.cert519_denied($q$delete from public.delivery_addresses where id=pg_temp.cert519_id('ad1')$q$,'permission denied','direct address delete denied');
select pg_temp.cert519_denied($q$select * from public.customer_saved_transporters$q$,'permission denied','direct transporter table denied');

select pg_temp.cert519_act('b1');
select pg_temp.cert519_check((select count(*)=0 from public.customer_delivery_addresses_v1()),'other company cannot list addresses');
select pg_temp.cert519_check((select count(*)=0 from public.customer_saved_transporters_v1()),'other company cannot list transporters');
select pg_temp.cert519_denied($q$select * from public.customer_upsert_delivery_address_v1(pg_temp.cert519_id('ad1'),'HIJACK','x','x','x','1')$q$,'BUYER_ADDRESS_SCOPE_REQUIRED','cross-company address update denied');
select pg_temp.cert519_denied($q$select public.customer_delete_delivery_address_v1(pg_temp.cert519_id('ad1'))$q$,'BUYER_ADDRESS_NOT_FOUND','cross-company address delete denied');
select pg_temp.cert519_denied($q$select * from public.customer_upsert_saved_transporter_v1(pg_temp.cert519_id('tr1'),'HIJACK',null,false,true)$q$,'BUYER_TRANSPORTER_SCOPE_REQUIRED','cross-company transporter update denied');
select pg_temp.cert519_denied($q$select public.customer_delete_saved_transporter_v1(pg_temp.cert519_id('tr1'))$q$,'BUYER_TRANSPORTER_NOT_FOUND','cross-company transporter delete denied');

select pg_temp.cert519_act('pending');
select pg_temp.cert519_denied($q$select * from public.customer_upsert_delivery_address_v1(gen_random_uuid(),'PENDING','x','x','x','1')$q$,'BUYER_ADDRESS_ELIGIBILITY_REQUIRED','pending address denied');
select pg_temp.cert519_denied($q$select * from public.customer_upsert_saved_transporter_v1(gen_random_uuid(),'PENDING',null,false,true)$q$,'BUYER_TRANSPORTER_ELIGIBILITY_REQUIRED','pending transporter denied');
select pg_temp.cert519_act('frozen');
select pg_temp.cert519_denied($q$select * from public.customer_upsert_delivery_address_v1(gen_random_uuid(),'FROZEN','x','x','x','1')$q$,'BUYER_ADDRESS_ELIGIBILITY_REQUIRED','frozen company denied');
select pg_temp.cert519_act('staff');
select pg_temp.cert519_denied($q$select * from public.customer_upsert_saved_transporter_v1(gen_random_uuid(),'STAFF',null,false,true)$q$,'BUYER_TRANSPORTER_ELIGIBILITY_REQUIRED','staff denied');

select pg_temp.cert519_act('a1');
select pg_temp.cert519_check(public.customer_delete_saved_transporter_v1(pg_temp.cert519_id('tr2')),'transporter delete');
select pg_temp.cert519_check((select is_default from public.customer_saved_transporters_v1() where transporter_id=pg_temp.cert519_id('tr1')),'transporter replacement default');
select pg_temp.cert519_check(public.customer_delete_delivery_address_v1(pg_temp.cert519_id('ad2')),'address delete');
select pg_temp.cert519_check((select is_default from public.customer_delivery_addresses_v1() where address_id=pg_temp.cert519_id('ad1')),'address replacement default');
reset role;
insert into public.delivery_addresses(id,company_id,user_id,label,street_address,city,state,pincode,is_default)
values(pg_temp.cert519_id('private'),null,pg_temp.cert519_id('a1'),'PRIVATE','4 Synthetic Road','Delhi','DL','110001',true);
set local role authenticated;
select pg_temp.cert519_check((select count(*)=1 from public.customer_delivery_addresses_v1() where is_default),'private override gives one effective default');
select pg_temp.cert519_act('a2');
select pg_temp.cert519_check((select count(*)=0 from public.customer_delivery_addresses_v1() where address_id=pg_temp.cert519_id('private')),'private legacy address hidden from same-company peer');
select pg_temp.cert519_act('a1');
select pg_temp.cert519_check(public.customer_delete_delivery_address_v1(pg_temp.cert519_id('private')),'private legacy default deletion');
select pg_temp.cert519_check((select count(*)=1 from public.customer_delivery_addresses_v1() where is_default),'private deletion retains one shared default');
reset role;
select jsonb_build_object('target','stkvyotdkysieuvpuues','kind','hosted-real-SQL-role-probe-not-GoTrue-or-device','passed',(select count(*) from cert519_results),'checks',(select jsonb_agg(label order by label) from cert519_results),'fixture_disposition','ROLLBACK follows this SELECT; cleanup independently verified afterward') as report;
rollback;
