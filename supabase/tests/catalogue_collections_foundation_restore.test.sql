begin;
-- Contract coverage for 20261018143000_catalogue_collections_foundation_restore.sql
select plan(20);

select has_table('public', 'catalogue_collections', 'catalogue_collections exists');
select has_table('public', 'catalogue_collection_items', 'catalogue_collection_items exists');
select has_table('public', 'catalogue_share_links', 'catalogue_share_links exists');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.catalogue_collections'::regclass),
  'catalogue_collections has RLS enabled'
);

select ok(
  not has_table_privilege('anon', 'public.catalogue_collections', 'SELECT'),
  'anon cannot SELECT catalogue_collections'
);
select ok(
  not has_table_privilege('anon', 'public.catalogue_share_links', 'SELECT'),
  'anon cannot SELECT catalogue_share_links (share tokens stay staff-only)'
);

SET LOCAL session_replication_role = replica;

insert into auth.users (id, email) values
  ('19000000-0000-0000-0000-000000000001', 'collections-reviewer@test.invalid'),
  ('19000000-0000-0000-0000-000000000002', 'collections-sales@test.invalid'),
  ('19000000-0000-0000-0000-000000000099', 'collections-outsider@test.invalid');

insert into public.users (id, role) values
  ('19000000-0000-0000-0000-000000000001', 'super_admin'),
  ('19000000-0000-0000-0000-000000000002', 'sales');

-- is_team_member() reads user_role_map + roles.role_key (not users.role alone).
-- CI replay seeds super_admin via WA-2 but not sales; provision both explicitly.
insert into public.roles (id, role_key, role_name, is_active) values
  ('19000000-0000-0000-0000-00000000a001', 'super_admin', 'Super Admin', true),
  ('19000000-0000-0000-0000-00000000a002', 'sales', 'Sales', true)
on conflict (role_key) do update set is_active = true;

insert into public.user_role_map (user_id, role_id)
select fixture.user_id, r.id
from (
  values
    ('19000000-0000-0000-0000-000000000001'::uuid, 'super_admin'),
    ('19000000-0000-0000-0000-000000000002'::uuid, 'sales')
) as fixture(user_id, role_key)
join public.roles r
  on r.role_key = fixture.role_key and coalesce(r.is_active, true)
on conflict (user_id, role_id) do nothing;

SET LOCAL session_replication_role = origin;

select is(
  public.is_team_member('19000000-0000-0000-0000-000000000002'::uuid),
  true,
  'sales fixture is recognised as a team member via user_role_map'
);
select is(
  public.is_team_member('19000000-0000-0000-0000-000000000001'::uuid),
  true,
  'catalogue reviewer fixture is recognised as a team member via user_role_map'
);

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('29000000-0000-0000-0000-000000000001', 'Collection Product A', 'sweets', 'COLL-PROD-A', '1905', 'arabic_sweets');

-- outsider (authenticated but not team) cannot read collections
set local role authenticated;
set local request.jwt.claim.sub = '19000000-0000-0000-0000-000000000099';
set local request.jwt.claim.role = 'authenticated';

select is(
  (select count(*)::integer from public.catalogue_collections),
  0,
  'non-team authenticated user sees no catalogue_collections rows'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- team sales can create draft collection and items
set local role authenticated;
set local request.jwt.claim.sub = '19000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';

select is(
  public.is_catalogue_reviewer(),
  false,
  'sales team member is not a catalogue reviewer'
);

select lives_ok(
  $$ insert into public.catalogue_collections (id, title, slug, status)
     values ('39000000-0000-0000-0000-000000000001', 'Wholesale Autumn', 'wholesale-autumn-test', 'draft') $$,
  'team member can insert draft catalogue collection'
);

select lives_ok(
  $$ insert into public.catalogue_collection_items (collection_id, product_id, sort_order)
     values ('39000000-0000-0000-0000-000000000001', '29000000-0000-0000-0000-000000000001', 0) $$,
  'team member can add a product to a collection'
);

select throws_ok(
  $$ update public.catalogue_collections
     set status = 'published'
     where id = '39000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'non-reviewer team member cannot publish a collection'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- reviewer can publish
set local role authenticated;
set local request.jwt.claim.sub = '19000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select is(
  public.is_catalogue_reviewer(),
  true,
  'super_admin fixture is a catalogue reviewer'
);

select lives_ok(
  $$ update public.catalogue_collections
     set status = 'published'
     where id = '39000000-0000-0000-0000-000000000001' $$,
  'catalogue reviewer can publish a collection'
);

select lives_ok(
  $$ insert into public.catalogue_share_links (collection_id, share_token, share_type, status)
     values ('39000000-0000-0000-0000-000000000001', 'share_test_token_01', 'view', 'active') $$,
  'team member can create share link while collection is published'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- outsider cannot read share tokens
set local role authenticated;
set local request.jwt.claim.sub = '19000000-0000-0000-0000-000000000099';
set local request.jwt.claim.role = 'authenticated';

select is(
  (select count(*)::integer from public.catalogue_share_links),
  0,
  'non-team user cannot read catalogue_share_links'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- invalid product reference fails closed
set local role authenticated;
set local request.jwt.claim.sub = '19000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';

select throws_ok(
  $$ insert into public.catalogue_collection_items (collection_id, product_id)
     values ('39000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000099') $$,
  '23503',
  null,
  'invalid product_id is rejected by FK'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- ON DELETE CASCADE removes items when collection is deleted (service_role)
delete from public.catalogue_collections where id = '39000000-0000-0000-0000-000000000001';

select is(
  (select count(*)::integer from public.catalogue_collection_items
     where collection_id = '39000000-0000-0000-0000-000000000001'),
  0,
  'deleting a collection cascades to catalogue_collection_items'
);

select is(
  (select count(*)::integer from public.catalogue_share_links
     where collection_id = '39000000-0000-0000-0000-000000000001'),
  0,
  'deleting a collection cascades to catalogue_share_links'
);

select * from finish();
rollback;
