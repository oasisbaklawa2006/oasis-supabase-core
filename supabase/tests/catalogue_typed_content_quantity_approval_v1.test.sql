begin;
-- Contract test for 20261109100000_catalogue_typed_content_quantity_approval_v1.sql.
-- Core #486: rollback-only tested typed content authority. Never run against production.
select plan(29);

select has_function('public', 'catalogue_parse_typed_content_quantity_v1', array['jsonb']);
select ok(not has_function_privilege('anon', 'public.catalogue_parse_typed_content_quantity_v1(jsonb)', 'EXECUTE'),'anon cannot call internal quantity parser');
select ok(not has_function_privilege('authenticated', 'public.catalogue_parse_typed_content_quantity_v1(jsonb)', 'EXECUTE'),'ordinary users cannot call internal quantity parser');
select is((select present from public.catalogue_parse_typed_content_quantity_v1('{}'::jsonb)), false,'legacy drafts without typed content remain compatible');
select is((select pcs_per_pack from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":6,"unit":"pcs"}}}'::jsonb)),6::numeric,'six explicitly reviewed pieces persist as six');
select is((select net_weight_grams from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":6,"unit":"pcs"}}}'::jsonb)),NULL::numeric,'pieces never fabricate grams');
select is((select net_weight_grams from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":140.5,"unit":"g"}}}'::jsonb)),140.5::numeric,'explicit gram content is preserved');
select is((select net_weight_grams from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":0.5,"unit":"kg"}}}'::jsonb)),500::numeric,'explicit kilograms normalize to grams, not carton conversions');
select is((select pcs_per_pack from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":0.5,"unit":"kg"}}}'::jsonb)),NULL::numeric,'weight is never interpreted as pieces');
select throws_ok($$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":0,"unit":"pcs"}}}'::jsonb)$$,'P0001',null,'zero pieces denied');
select throws_ok($$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":-3,"unit":"pcs"}}}'::jsonb)$$,'P0001',null,'negative pieces denied');
select throws_ok($$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":2.5,"unit":"pcs"}}}'::jsonb)$$,'P0001',null,'fractional pieces denied');
select throws_ok($$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":"6","unit":"pcs"}}}'::jsonb)$$,'P0001',null,'numeric strings denied');
select throws_ok($$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":6,"unit":"tray"}}}'::jsonb)$$,'P0001',null,'unknown units denied');
select throws_ok($$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":6,"unit":"pcs","trays":8}}}'::jsonb)$$,'P0001',null,'unapproved conversion fields denied');
select throws_ok($$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":null}}'::jsonb)$$,'P0001',null,'explicit null denied');
select throws_ok($$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":"6 pcs"}}'::jsonb)$$,'P0001',null,'untyped scalar denied');
select throws_ok($$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":9007199254740992,"unit":"pcs"}}}'::jsonb)$$,'P0001',null,'unsafe integer count denied');

-- Synthetic fixtures are always wrapped in a rollback-only transaction.
set local session_replication_role=replica;
insert into auth.users(id,email) values ('48600000-0000-0000-0000-000000000001','reviewer486@example.invalid');
insert into public.users(id,role,is_active) values ('48600000-0000-0000-0000-000000000001','super_admin',true);
insert into public.roles(id,role_key,role_name,is_active) values
 ('48600000-0000-0000-0000-00000000a001','super_admin','Super Admin',true)
on conflict(role_key) do update set is_active=true;
insert into public.user_role_map(user_id,role_id)
select '48600000-0000-0000-0000-000000000001'::uuid,id from public.roles
where role_key='super_admin' on conflict (user_id,role_id) do nothing;
set local session_replication_role=origin;

insert into public.catalogue_product_drafts(id,operation,payload,submitted_by) values
 ('48600000-0000-0000-0000-000000000011','create',
  '{"identity":{"product_name":"Core486 Synthetic Six Pieces","category":"Baklawa","production_department":"arabic_sweets"},"sku_draft":{"sku":"OAS-AS-BKL-C486-BOX-0001"},"pricing":{"hsn":"1905"},"packing":{"content_quantity":{"value":6,"unit":"pcs"}}}'::jsonb,
  '48600000-0000-0000-0000-000000000001'),
 ('48600000-0000-0000-0000-000000000012','update',
  '{"identity":{"product_name":"Core486 Synthetic Six Pieces","category":"Baklawa"},"packing":{"content_quantity":{"value":0.5,"unit":"kg"}}}'::jsonb,
  '48600000-0000-0000-0000-000000000001'),
 ('48600000-0000-0000-0000-000000000013','create',
  '{"identity":{"product_name":"Core486 Rejected Pieces","category":"Baklawa"},"sku_draft":{"sku":"OAS-AS-BKL-C486-BOX-0002"},"packing":{"content_quantity":{"value":2.5,"unit":"pcs"}}}'::jsonb,
  '48600000-0000-0000-0000-000000000001');

set local role authenticated;
set local request.jwt.claim.sub='48600000-0000-0000-0000-000000000001';
set local request.jwt.claim.role='authenticated';

select is(public.is_catalogue_reviewer(),true,'synthetic reviewer has current Core review permission');
select lives_ok($$select public.approve_catalogue_product_draft(
  '48600000-0000-0000-0000-000000000011'::uuid)$$,'approved create persists reviewer-verified content');
select is((select status from public.catalogue_product_drafts where id='48600000-0000-0000-0000-000000000011'),'approved','create approval is committed atomically');
select is((select pcs_per_pack from public.products where sku='OAS-AS-BKL-C486-BOX-0001'),6::numeric,'Product Master readback contains six pieces');
select is((select net_weight_grams from public.products where sku='OAS-AS-BKL-C486-BOX-0001'),NULL::numeric,'no inferred weight on piece-only create');
reset role;
-- Only the trusted test harness may set target_record_id; normal reviewers
-- use the governed wrapper which reads that authority from the locked draft.
update public.catalogue_product_drafts set target_record_id=(
  select id from public.products where sku='OAS-AS-BKL-C486-BOX-0001'
) where id='48600000-0000-0000-0000-000000000012';
set local role authenticated;
select lives_ok($$select public.approve_catalogue_product_draft(
  '48600000-0000-0000-0000-000000000012'::uuid)$$,'approved update can map an independent explicit weight');
select is((select net_weight_grams from public.products where sku='OAS-AS-BKL-C486-BOX-0001'),500::numeric,'approved update preserves explicit net grams');
select is((select pcs_per_pack from public.products where sku='OAS-AS-BKL-C486-BOX-0001'),6::numeric,'weight update does not overwrite piece count');
select throws_ok($$select public.approve_catalogue_product_draft(
  '48600000-0000-0000-0000-000000000013'::uuid)$$,'P0001',null,'unapproved fractional quantity fails product approval');
select is((select status from public.catalogue_product_drafts where id='48600000-0000-0000-0000-000000000013'),'pending_approval','rejected approval remains pending');
select is((select count(*)::integer from public.products where sku in ('OAS-AS-BKL-C486-BOX-0001','OAS-AS-BKL-C486-BOX-0002')),1,'invalid draft never writes Product Master');
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;
select * from finish();
rollback;
