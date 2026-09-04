begin;
-- Contract coverage for 20260904030100_point29_atomic_intake_barcode_authority.sql.

select plan(28);

select has_function('public', 'catalogue_extract_reviewed_intake_barcode', array['jsonb']);
select has_function('public', 'catalogue_validate_intake_barcode', array['text']);
select has_function('public', 'catalogue_claim_intake_barcode', array['text', 'uuid']);
select has_function('public', 'catalogue_approve_product_draft_atomic_v1', array['text', 'uuid', 'jsonb', 'jsonb', 'text', 'uuid']);
select has_function('public', 'submit_catalogue_product_draft_v1', array['text', 'uuid', 'jsonb']);

insert into public.permissions (id, permission_key, module_name, permission_name)
values ('a2900000-0000-0000-0000-000000000201', 'catalogue.products.submit', 'catalogue', 'Submit product drafts')
on conflict (permission_key) do nothing;

insert into public.roles (id, role_key, role_name, is_active)
values ('a2900000-0000-0000-0000-000000000202', 'catalogue_contributor', 'Catalogue contributor', true)
on conflict (role_key) do update set is_active = true;

insert into public.role_permission_map (role_id, permission_id)
select r.id, p.id
  from public.roles r
  join public.permissions p on p.permission_key = 'catalogue.products.submit'
 where r.role_key = 'catalogue_contributor'
on conflict (role_id, permission_id) do nothing;

insert into auth.users (id, email) values
  ('a2900000-0000-0000-0000-000000000001', 'point29-reviewer@example.invalid'),
  ('a2900000-0000-0000-0000-000000000002', 'point29-contributor@example.invalid'),
  ('a2900000-0000-0000-0000-000000000003', 'point29-unauthorized@example.invalid'),
  ('a2900000-0000-0000-0000-000000000004', 'point29-contributor-b@example.invalid');

insert into public.users (id, role) values
  ('a2900000-0000-0000-0000-000000000001', 'super_admin'),
  ('a2900000-0000-0000-0000-000000000002', 'catalogue_contributor'),
  ('a2900000-0000-0000-0000-000000000003', 'sales_executive'),
  ('a2900000-0000-0000-0000-000000000004', 'catalogue_contributor');

insert into public.products (id, name, category, sku, hsn_code, barcode_sku)
values (
  'a2900000-0000-0000-0000-000000000010',
  'Point29 Existing Product',
  'sweets',
  'P29-EXISTING-SKU',
  '1905',
  'P29-EXISTING-BC'
);

insert into public.catalogue_product_drafts (
  id, operation, payload, status, submitted_by
) values
  (
    'a2900000-0000-0000-0000-000000000101',
    'create',
    jsonb_build_object(
      'identity', jsonb_build_object('product_name', 'Point29 Create A', 'category', 'sweets'),
      'sku_draft', jsonb_build_object('sku', 'P29-CREATE-A'),
      'pricing', jsonb_build_object('hsn', '1905'),
      'intake_barcode', 'P29-BC-CREATE-A'
    ),
    'pending_approval',
    'a2900000-0000-0000-0000-000000000002'
  ),
  (
    'a2900000-0000-0000-0000-000000000102',
    'create',
    jsonb_build_object(
      'identity', jsonb_build_object('product_name', 'Point29 Duplicate', 'category', 'sweets'),
      'sku_draft', jsonb_build_object('sku', 'P29-DUP-FAIL'),
      'pricing', jsonb_build_object('hsn', '1905'),
      'intake_barcode', 'P29-EXISTING-BC'
    ),
    'pending_approval',
    'a2900000-0000-0000-0000-000000000002'
  ),
  (
    'a2900000-0000-0000-0000-000000000103',
    'create',
    jsonb_build_object(
      'identity', jsonb_build_object('product_name', 'Point29 Invalid', 'category', 'sweets'),
      'sku_draft', jsonb_build_object('sku', 'P29-INVALID'),
      'pricing', jsonb_build_object('hsn', '1905'),
      'intake_barcode', 'bad'
    ),
    'pending_approval',
    'a2900000-0000-0000-0000-000000000002'
  ),
  (
    'a2900000-0000-0000-0000-000000000104',
    'update',
    jsonb_build_object(
      'identity', jsonb_build_object('product_name', 'Point29 Updated', 'category', 'sweets'),
      'sku_draft', jsonb_build_object('sku', 'P29-EXISTING-SKU'),
      'pricing', jsonb_build_object('hsn', '1905'),
      'labeling', jsonb_build_object('intake_barcode', 'P29-UPDATED-BC')
    ),
    'pending_approval',
    'a2900000-0000-0000-0000-000000000002'
  ),
  (
    'a2900000-0000-0000-0000-000000000105',
    'update',
    jsonb_build_object(
      'identity', jsonb_build_object('product_name', 'Point29 Update Missing Target', 'category', 'sweets'),
      'sku_draft', jsonb_build_object('sku', 'P29-UPDATE-NO-TARGET'),
      'pricing', jsonb_build_object('hsn', '1905'),
      'intake_barcode', 'P29-UPDATE-NO-TARGET-BC'
    ),
    'pending_approval',
    'a2900000-0000-0000-0000-000000000002'
  ),
  (
    'a2900000-0000-0000-0000-000000000106',
    'delete_request',
    jsonb_build_object(
      'identity', jsonb_build_object('product_name', 'Point29 Delete Request', 'category', 'sweets'),
      'sku_draft', jsonb_build_object('sku', 'P29-DELETE-REQ'),
      'pricing', jsonb_build_object('hsn', '1905')
    ),
    'pending_approval',
    'a2900000-0000-0000-0000-000000000002'
  ),
  (
    'a2900000-0000-0000-0000-000000000107',
    'create',
    jsonb_build_object(
      'identity', jsonb_build_object('product_name', 'Point29 Conflict Holder', 'category', 'sweets'),
      'sku_draft', jsonb_build_object('sku', 'P29-CONFLICT-SKU'),
      'pricing', jsonb_build_object('hsn', '1905'),
      'intake_barcode', 'P29-CONFLICT-BC'
    ),
    'pending_approval',
    'a2900000-0000-0000-0000-000000000002'
  );

update public.catalogue_product_drafts
   set target_record_id = 'a2900000-0000-0000-0000-000000000010'
 where id = 'a2900000-0000-0000-0000-000000000104';

update public.catalogue_product_drafts
   set target_record_id = 'a2900000-0000-0000-0000-000000000010'
 where id = 'a2900000-0000-0000-0000-000000000106';

set local role authenticated;
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'a2900000-0000-0000-0000-000000000003';

select throws_ok(
  $$select public.approve_catalogue_product_draft('a2900000-0000-0000-0000-000000000101')$$,
  'Catalogue reviewer permission required',
  'unauthorized actors cannot approve product drafts'
);

reset role;
set local request.jwt.claim.sub = 'a2900000-0000-0000-0000-000000000003';

select throws_ok(
  $$select public.catalogue_approve_product_draft_atomic_v1(
    'catalogue_product_drafts',
    'a2900000-0000-0000-0000-000000000102',
    (select to_jsonb(d) from public.catalogue_product_drafts d where d.id = 'a2900000-0000-0000-0000-000000000102'),
    (select d.payload from public.catalogue_product_drafts d where d.id = 'a2900000-0000-0000-0000-000000000102'),
    'create',
    null
  )$$,
  'Catalogue reviewer permission required',
  'direct atomic approval denies non-reviewers fail-closed inside the function'
);

set local role authenticated;
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'a2900000-0000-0000-0000-000000000003';

select throws_ok(
  $$select public.catalogue_approve_product_draft_atomic_v1(
    'catalogue_product_drafts',
    'a2900000-0000-0000-0000-000000000102',
    '{}'::jsonb,
    '{}'::jsonb,
    'create',
    null
  )$$,
  'permission denied for function catalogue_approve_product_draft_atomic_v1',
  'authenticated callers cannot execute the atomic approval RPC directly'
);

set local request.jwt.claim.sub = 'a2900000-0000-0000-0000-000000000001';

select is(
  (select public.approve_catalogue_product_draft('a2900000-0000-0000-0000-000000000101') ->> 'intake_barcode'),
  'P29-BC-CREATE-A',
  'positive create approval persists reviewed intake_barcode atomically'
);

select is(
  (
    select p.barcode_sku
      from public.products p
      join public.catalogue_product_drafts d on d.target_record_id = p.id
     where d.id = 'a2900000-0000-0000-0000-000000000101'
  ),
  'P29-BC-CREATE-A',
  'approved product row carries barcode_sku from reviewed intake_barcode'
);

select is(
  (select count(*)::int from public.catalogue_approval_audit where draft_id = 'a2900000-0000-0000-0000-000000000101'),
  1,
  'approval writes immutable catalogue audit evidence'
);

select throws_ok(
  $$select public.approve_catalogue_product_draft('a2900000-0000-0000-0000-000000000101')$$,
  'Only pending_approval drafts can be approved. Current status: approved',
  're-approving the same draft is fail-closed'
);

select throws_ok(
  $$select public.approve_catalogue_product_draft('a2900000-0000-0000-0000-000000000102')$$,
  'CATALOGUE_INTAKE_BARCODE_DUPLICATE',
  'duplicate reviewed intake_barcode rejects approval'
);

select is(
  (select count(*)::int from public.products where sku = 'P29-DUP-FAIL'),
  0,
  'duplicate barcode failure rolls back product creation'
);

select is(
  (select status from public.catalogue_product_drafts where id = 'a2900000-0000-0000-0000-000000000102'),
  'pending_approval',
  'duplicate barcode failure leaves the draft pending for correction'
);

select throws_ok(
  $$select public.approve_catalogue_product_draft('a2900000-0000-0000-0000-000000000103')$$,
  'CATALOGUE_INTAKE_BARCODE_INVALID',
  'invalid reviewed intake_barcode is rejected before product commit'
);

select is(
  (select public.approve_catalogue_product_draft('a2900000-0000-0000-0000-000000000104') ->> 'intake_barcode'),
  'P29-UPDATED-BC',
  'contributor update drafts propagate nested labeling.intake_barcode on approval'
);

select is(
  (select barcode_sku from public.products where id = 'a2900000-0000-0000-0000-000000000010'),
  'P29-UPDATED-BC',
  'update approval atomically replaces products.barcode_sku'
);

set local request.jwt.claim.sub = 'a2900000-0000-0000-0000-000000000002';

select is(
  (
    select s.draft_id
      from public.submit_catalogue_product_draft_v1(
        'create',
        null,
        jsonb_build_object(
          'identity', jsonb_build_object('product_name', 'Point29 Contributor', 'category', 'sweets'),
          'sku_draft', jsonb_build_object('sku', 'P29-CONTRIB-SKU', 'intake_barcode', 'P29-CONTRIB-BC'),
          'pricing', jsonb_build_object('hsn', '1905')
        )
      ) s
  ),
  (
    select s.draft_id
      from public.submit_catalogue_product_draft_v1(
        'create',
        null,
        jsonb_build_object(
          'identity', jsonb_build_object('product_name', 'Point29 Contributor', 'category', 'sweets'),
          'sku_draft', jsonb_build_object('sku', 'P29-CONTRIB-SKU', 'intake_barcode', 'P29-CONTRIB-BC'),
          'pricing', jsonb_build_object('hsn', '1905')
        )
      ) s
  ),
  'contributor submit is idempotent for the same SKU while pending'
);

select ok(
  (
    select s.already_pending
      from public.submit_catalogue_product_draft_v1(
        'create',
        null,
        jsonb_build_object(
          'identity', jsonb_build_object('product_name', 'Point29 Contributor', 'category', 'sweets'),
          'sku_draft', jsonb_build_object('sku', 'P29-CONTRIB-SKU', 'intake_barcode', 'P29-CONTRIB-BC'),
          'pricing', jsonb_build_object('hsn', '1905')
        )
      ) s
  ),
  'contributor submit replay reports already_pending'
);

set local request.jwt.claim.sub = 'a2900000-0000-0000-0000-000000000001';

select is(
  (
    select d.payload #>> '{sku_draft,intake_barcode}'
      from public.catalogue_product_drafts d
     where lower(d.payload #>> '{sku_draft,sku}') = lower('P29-CONTRIB-SKU')
     order by d.created_at desc
     limit 1
  ),
  'P29-CONTRIB-BC',
  'contributor payload preserves nested intake_barcode until reviewer approval'
);

select lives_ok(
  $$
    select public.approve_catalogue_product_draft(
      (
        select d.id
          from public.catalogue_product_drafts d
         where lower(d.payload #>> '{sku_draft,sku}') = lower('P29-CONTRIB-SKU')
           and d.status = 'pending_approval'
         order by d.created_at desc
         limit 1
      )
    )
  $$,
  'reviewer approval of contributor draft succeeds'
);

select is(
  (
    select p.barcode_sku
      from public.products p
     where p.sku = 'P29-CONTRIB-SKU'
  ),
  'P29-CONTRIB-BC',
  'contributor approval path commits reviewed intake_barcode with the product'
);

select throws_ok(
  $$select public.approve_catalogue_product_draft('a2900000-0000-0000-0000-000000000105')$$,
  'Product draft update requires target_record_id',
  'update drafts without target_record_id are rejected before product writes'
);

select throws_ok(
  $$select public.approve_catalogue_product_draft('a2900000-0000-0000-0000-000000000106')$$,
  'Unsupported product draft operation: delete_request',
  'delete_request product drafts are explicitly rejected at approval'
);

select is(
  (select status from public.catalogue_product_drafts where id = 'a2900000-0000-0000-0000-000000000106'),
  'pending_approval',
  'delete_request rejection leaves the draft pending for governed handling elsewhere'
);

select is(
  (select count(*)::int from public.catalogue_approval_audit where draft_id = 'a2900000-0000-0000-0000-000000000106'),
  0,
  'delete_request rejection writes no approval audit evidence'
);

set local request.jwt.claim.sub = 'a2900000-0000-0000-0000-000000000004';

select throws_ok(
  $$select public.submit_catalogue_product_draft_v1(
    'create',
    null,
    jsonb_build_object(
      'identity', jsonb_build_object('product_name', 'Point29 Conflict Attempt', 'category', 'sweets'),
      'sku_draft', jsonb_build_object('sku', 'P29-CONFLICT-SKU'),
      'pricing', jsonb_build_object('hsn', '1905'),
      'intake_barcode', 'P29-OTHER-BC'
    )
  )$$,
  'CATALOGUE_PRODUCT_DRAFT_SKU_CONFLICT',
  'cross-contributor SKU replay raises an explicit conflict instead of returning another draft id'
);

set local request.jwt.claim.sub = 'a2900000-0000-0000-0000-000000000002';

select isnt(
  (
    select s.draft_id
      from public.submit_catalogue_product_draft_v1(
        'update',
        'a2900000-0000-0000-0000-000000000010',
        jsonb_build_object(
          'identity', jsonb_build_object('product_name', 'Point29 Multi Op', 'category', 'sweets'),
          'sku_draft', jsonb_build_object('sku', 'P29-MULTI-OP'),
          'pricing', jsonb_build_object('hsn', '1905'),
          'intake_barcode', 'P29-MULTI-OP-BC'
        )
      ) s
  ),
  (
    select s.draft_id
      from public.submit_catalogue_product_draft_v1(
        'create',
        null,
        jsonb_build_object(
          'identity', jsonb_build_object('product_name', 'Point29 Multi Op', 'category', 'sweets'),
          'sku_draft', jsonb_build_object('sku', 'P29-MULTI-OP'),
          'pricing', jsonb_build_object('hsn', '1905'),
          'intake_barcode', 'P29-MULTI-OP-BC'
        )
      ) s
  ),
  'same contributor with different operation and target creates a separate pending draft'
);

select * from finish();
rollback;
