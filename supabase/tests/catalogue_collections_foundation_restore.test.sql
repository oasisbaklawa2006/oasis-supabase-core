begin;
-- Contract coverage for 20261107110000_catalogue_collections_foundation_restore.sql
-- Source: closed Core PR #417; reviewer-hardening source-stage reference #485.
select plan(38);

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
  ('29000000-0000-0000-0000-000000000001', 'Collection Product A', 'sweets', 'COLL-PROD-A', '1905', 'arabic_sweets'),
  ('29000000-0000-0000-0000-000000000002', 'Collection Product B', 'sweets', 'COLL-PROD-B', '1905', 'arabic_sweets');

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
  $$ insert into public.catalogue_share_links (collection_id, share_token, share_type, status)
     values ('39000000-0000-0000-0000-000000000001', 'sales_draft_token', 'view', 'active') $$,
  '42501',
  null,
  'sales staff cannot mint a share token on a draft collection'
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

select throws_ok(
  $$ insert into public.catalogue_share_links (collection_id, share_token, share_type, status)
     values ('39000000-0000-0000-0000-000000000001', 'reviewer_draft_token', 'view', 'active') $$,
  '42501',
  null,
  'reviewer cannot issue a share token until the collection is published'
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
  'catalogue reviewer can create a share link after publication'
);
select is(
  (select count(*)::integer from public.catalogue_share_links where share_token = 'share_test_token_01'),
  1,
  'reviewer can read share-token records for governed revocation'
);

-- Keep one published link active through the later archive transition;
-- use a second token to exercise the separate explicit-revoke workflow.
select lives_ok(
  $$ insert into public.catalogue_share_links (collection_id, share_token, share_type, status)
     values ('39000000-0000-0000-0000-000000000001', 'share_test_token_manual_02', 'view', 'active') $$,
  'reviewer can mint another approved published-collection share token'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- Sales can still read published catalogues, but never read bearer share tokens.
-- This is a meaningful negative assertion because a reviewer inserted the token.
set local role authenticated;
set local request.jwt.claim.sub = '19000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';

select is(
  (select count(*)::integer from public.catalogue_share_links),
  0,
  'non-reviewer sales cannot read bearer share-token records'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- Run DML as the current JWT-authenticated role and inspect actual affected
-- rows, since pgTAP's outer SELECT cannot nest data-modifying WITH queries.
-- This helper is test-only and SECURITY INVOKER (never bypasses row policies).
create function pg_temp.g3_affected_rows(p_sql text)
returns integer language plpgsql security invoker as $g3$
declare n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end
$g3$;
grant execute on function pg_temp.g3_affected_rows(text) to authenticated;

-- Sales can still read published catalogues, but cannot mutate published content
-- or mint/revoke public share tokens. UPDATE and DELETE are RLS-filtered to zero
-- affected rows; assert the count rather than assuming they raise an error.
set local role authenticated;
set local request.jwt.claim.sub = '19000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';

select throws_ok(
  $$ insert into public.catalogue_share_links (collection_id, share_token, share_type, status)
     values ('39000000-0000-0000-0000-000000000001', 'sales_published_token', 'view', 'active') $$,
  '42501',
  null,
  'non-reviewer cannot mint share token for a published collection'
);

select is(
  pg_temp.g3_affected_rows($$update public.catalogue_collections
       set status = 'draft'
     where id = '39000000-0000-0000-0000-000000000001'$$),
  0,
  'non-reviewer cannot unpublish an already published collection'
);

select is(
  pg_temp.g3_affected_rows($$delete from public.catalogue_collections
     where id = '39000000-0000-0000-0000-000000000001'$$),
  0,
  'non-reviewer cannot delete a published collection'
);

select is(
  pg_temp.g3_affected_rows($$update public.catalogue_share_links set status = 'revoked'
     where share_token = 'share_test_token_01'$$),
  0,
  'non-reviewer cannot revoke a published share token'
);

select is(
  pg_temp.g3_affected_rows($$delete from public.catalogue_share_links
     where share_token = 'share_test_token_01'$$),
  0,
  'non-reviewer cannot delete a published share token'
);

select throws_ok(
  $$ insert into public.catalogue_collection_items (collection_id, product_id, sort_order)
     values ('39000000-0000-0000-0000-000000000001', '29000000-0000-0000-0000-000000000002', 1) $$,
  '42501',
  null,
  'non-reviewer cannot add a product to a published collection'
);

select is(
  pg_temp.g3_affected_rows($$update public.catalogue_collection_items set sort_order = 2
     where collection_id = '39000000-0000-0000-0000-000000000001'$$),
  0,
  'non-reviewer cannot reorder products in a published collection'
);

select is(
  pg_temp.g3_affected_rows($$delete from public.catalogue_collection_items
     where collection_id = '39000000-0000-0000-0000-000000000001'$$),
  0,
  'non-reviewer cannot remove published collection products'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- Reviewer can revoke links and archive published content, but cannot reactivate
-- links for collections that are no longer published.
set local role authenticated;
set local request.jwt.claim.sub = '19000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ update public.catalogue_share_links set status = 'revoked'
     where share_token = 'share_test_token_manual_02' $$,
  'reviewer can independently revoke a published share token'
);

select lives_ok(
  $$ update public.catalogue_collections set status = 'archived'
     where id = '39000000-0000-0000-0000-000000000001' $$,
  'reviewer can archive a previously published collection'
);

select is(
  (select status from public.catalogue_share_links
   where share_token = 'share_test_token_01'),
  'revoked',
  'archive trigger revokes the link that was still active at unpublication'
);
select is(
  (select count(*)::integer from public.catalogue_share_links
   where collection_id = '39000000-0000-0000-0000-000000000001'
     and status = 'active'),
  0,
  'no active catalogue share link remains after collection unpublication'
);

select throws_ok(
  $$ update public.catalogue_share_links set status = 'active'
     where share_token = 'share_test_token_01' $$,
  '42501',
  null,
  'reviewer cannot reactivate a share token for an archived collection'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- outsider (authenticated but not team) cannot read collections or share tokens.
-- Both checks run only after the published collection and share link exist, so a
-- regression that exposed rows to non-team users would be caught rather than
-- passing vacuously on an empty table.
set local role authenticated;
set local request.jwt.claim.sub = '19000000-0000-0000-0000-000000000099';
set local request.jwt.claim.role = 'authenticated';

select is(
  (select count(*)::integer from public.catalogue_collections),
  0,
  'non-team authenticated user sees no catalogue_collections rows'
);

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
