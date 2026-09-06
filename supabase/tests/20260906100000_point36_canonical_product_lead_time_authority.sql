-- Contract for migration 20260906100000_point36_canonical_product_lead_time_authority.sql
begin;

select plan(22);

select has_column(
  'public', 'products', 'lead_time_days',
  'products.lead_time_days is canonical Core dispatch lead-time authority'
);

select col_type_is(
  'public', 'products', 'lead_time_days', 'integer',
  'lead_time_days is integer'
);

select col_is_null(
  'public', 'products', 'lead_time_days',
  'lead_time_days is nullable for backward compatibility'
);

select ok(
  exists(
    select 1
    from pg_constraint
    where conname = 'products_lead_time_days_nonnegative_check'
      and conrelid = 'public.products'::regclass
  ),
  'lead_time_days has non-negative check constraint'
);

select ok(
  (
    select count(*) = 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'products'
      and column_name = 'lead_time_days'
  ),
  'lead_time_days is not duplicated on public.products'
);

select ok(
  position('dispatch' in lower(coalesce(col_description('public.products'::regclass, (
    select attnum from pg_attribute
    where attrelid = 'public.products'::regclass and attname = 'lead_time_days'
  )), ''))) > 0,
  'lead_time_days comment documents dispatch authority'
);

select ok(
  position('not derived' in lower(coalesce(col_description('public.products'::regclass, (
    select attnum from pg_attribute
    where attrelid = 'public.products'::regclass and attname = 'lead_time_days'
  )), ''))) > 0,
  'lead_time_days comment documents non-derived BOM relationship'
);

insert into public.products (
  id, name, category, sku, hsn_code,
  is_active, visible_in_catalog, is_catalogue_ready,
  lead_time_days
)
values (
  '00000000-0000-0000-0000-000000000036',
  'Point36 lead-time probe',
  'test',
  'P36-LT',
  '1234',
  true,
  true,
  true,
  7
);

select is(
  (select lead_time_days from public.products where id = '00000000-0000-0000-0000-000000000036'::uuid),
  7,
  'valid lead_time_days persists on write'
);

update public.products
set lead_time_days = null
where id = '00000000-0000-0000-0000-000000000036'::uuid;

select is(
  (select lead_time_days from public.products where id = '00000000-0000-0000-0000-000000000036'::uuid),
  null,
  'null lead_time_days round-trips as deferred/unknown'
);

select throws_ok(
  $$update public.products set lead_time_days = -1 where id = '00000000-0000-0000-0000-000000000036'::uuid$$,
  '23514',
  null,
  'lead_time_days rejects negative values on write'
);

select ok(
  lower(pg_get_function_result('public.published_products_v1()'::regprocedure)) like '%lead_time_days%',
  'published_products_v1 exposes lead_time_days in its return contract'
);

select is(
  (
    select lead_time_days
    from public.published_products_v1()
    where product_id = '00000000-0000-0000-0000-000000000036'::uuid
  ),
  null,
  'published_products_v1 returns null lead_time_days when authority is deferred'
);

update public.products
set lead_time_days = 14
where id = '00000000-0000-0000-0000-000000000036'::uuid;

select is(
  (
    select lead_time_days
    from public.published_products_v1()
    where product_id = '00000000-0000-0000-0000-000000000036'::uuid
  ),
  14,
  'published_products_v1 round-trips explicit lead_time_days'
);

select has_column(
  'public', 'products', 'carton_dimensions_cm',
  'Point35 carton_dimensions_cm authority is preserved'
);

select has_column(
  'public', 'products', 'cbm',
  'Point35 cbm authority is preserved'
);

select has_column(
  'public', 'products', 'gross_weight_kg',
  'Point35 gross_weight_kg authority is preserved'
);

select ok(
  not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'product_bom'
      and column_name = 'lead_time_days'
  ),
  'active product_bom does not expose a competing component lead_time_days column'
);

select ok(
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'published_products_v1'
      and p.prokind = 'f'
  ) = 1,
  'published_products_v1 remains a single governed function'
);

select ok(
  (select prosecdef from pg_proc where oid = 'public.published_products_v1()'::regprocedure),
  'published_products_v1 remains SECURITY DEFINER after Point36 extension'
);

select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
   from pg_proc
   where oid = 'public.published_products_v1()'::regprocedure),
  'published_products_v1 retains fixed search_path after Point36 extension'
);

select ok(
  position('lead_time_days' in lower(coalesce(obj_description('public.published_products_v1()'::regprocedure, 'pg_proc'), ''))) > 0,
  'published_products_v1 comment documents lead_time_days publication'
);

select * from finish();
rollback;
