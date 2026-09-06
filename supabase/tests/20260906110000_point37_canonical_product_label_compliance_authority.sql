-- Contract for migration 20260906110000_point37_canonical_product_label_compliance_authority.sql
begin;

select plan(26);

select has_column(
  'public', 'products', 'fssai_licence_number',
  'products.fssai_licence_number is canonical Core FSSAI label-compliance authority'
);

select has_column(
  'public', 'products', 'country_of_origin',
  'products.country_of_origin is canonical Core legal label country-of-origin authority'
);

select has_column(
  'public', 'products', 'label_manufacturer_details',
  'products.label_manufacturer_details is canonical Core manufacturer block authority'
);

select col_type_is(
  'public', 'products', 'fssai_licence_number', 'text',
  'fssai_licence_number is text'
);

select col_type_is(
  'public', 'products', 'country_of_origin', 'text',
  'country_of_origin is text'
);

select col_type_is(
  'public', 'products', 'label_manufacturer_details', 'text',
  'label_manufacturer_details is text'
);

select col_is_null(
  'public', 'products', 'fssai_licence_number',
  'fssai_licence_number is nullable for fail-closed backward compatibility'
);

select col_is_null(
  'public', 'products', 'country_of_origin',
  'country_of_origin is nullable for fail-closed backward compatibility'
);

select col_is_null(
  'public', 'products', 'label_manufacturer_details',
  'label_manufacturer_details is nullable for fail-closed backward compatibility'
);

select ok(
  exists(
    select 1
    from pg_constraint
    where conname = 'products_fssai_licence_number_format_check'
      and conrelid = 'public.products'::regclass
  ),
  'fssai_licence_number has 14-digit format check constraint'
);

select ok(
  position('14-digit' in lower(coalesce(col_description('public.products'::regclass, (
    select attnum from pg_attribute
    where attrelid = 'public.products'::regclass and attname = 'fssai_licence_number'
  )), ''))) > 0,
  'fssai_licence_number comment documents 14-digit authority'
);

select ok(
  position('companies.fssai_number' in lower(coalesce(col_description('public.products'::regclass, (
    select attnum from pg_attribute
    where attrelid = 'public.products'::regclass and attname = 'fssai_licence_number'
  )), ''))) > 0,
  'fssai_licence_number comment distinguishes buyer registration authority'
);

select ok(
  position('manufacturer' in lower(coalesce(col_description('public.products'::regclass, (
    select attnum from pg_attribute
    where attrelid = 'public.products'::regclass and attname = 'label_manufacturer_details'
  )), ''))) > 0,
  'label_manufacturer_details comment documents manufacturer block authority'
);

select ok(
  (
    select count(*) = 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'products'
      and column_name = 'fssai_licence_number'
  ),
  'fssai_licence_number is not duplicated on public.products'
);

select ok(
  not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'products'
      and column_name in ('fssai_license', 'fssai_number')
  ),
  'no shadow fssai_license or fssai_number columns on public.products'
);

insert into public.products (id, name, category, sku, hsn_code)
values ('00000000-0000-0000-0000-000000000037', 'Point37 compliance probe', 'test', 'P37-FSSAI', '1234');

select is(
  (select fssai_licence_number from public.products where id = '00000000-0000-0000-0000-000000000037'::uuid),
  null,
  'new products default fssai_licence_number to NULL (fail-closed)'
);

update public.products
set
  fssai_licence_number = '12345678901234',
  country_of_origin = 'India',
  label_manufacturer_details = 'Oasis Baklawa Pvt Ltd, New Delhi'
where id = '00000000-0000-0000-0000-000000000037'::uuid;

select is(
  (select fssai_licence_number from public.products where id = '00000000-0000-0000-0000-000000000037'::uuid),
  '12345678901234',
  'valid 14-digit fssai_licence_number persists on write'
);

select is(
  (select country_of_origin from public.products where id = '00000000-0000-0000-0000-000000000037'::uuid),
  'India',
  'country_of_origin persists on write'
);

select is(
  (select label_manufacturer_details from public.products where id = '00000000-0000-0000-0000-000000000037'::uuid),
  'Oasis Baklawa Pvt Ltd, New Delhi',
  'label_manufacturer_details persists on write'
);

select throws_ok(
  $$update public.products set fssai_licence_number = '12345' where id = '00000000-0000-0000-0000-000000000037'::uuid$$,
  '23514',
  null,
  'fssai_licence_number rejects non-14-digit values on write'
);

select throws_ok(
  $$update public.products set fssai_licence_number = '1234567890123a' where id = '00000000-0000-0000-0000-000000000037'::uuid$$,
  '23514',
  null,
  'fssai_licence_number rejects non-numeric values on write'
);

update public.products
set fssai_licence_number = null
where id = '00000000-0000-0000-0000-000000000037'::uuid;

select is(
  (select fssai_licence_number from public.products where id = '00000000-0000-0000-0000-000000000037'::uuid),
  null,
  'null fssai_licence_number round-trips as unknown/deferred'
);

select ok(
  not exists (
    select 1
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'labels'
      and not a.attisdropped
  ),
  'archived labels table is not reintroduced as shadow product compliance authority'
);

select ok(
  lower(pg_get_function_result('public.published_products_v1()'::regprocedure)) not like '%fssai%',
  'published_products_v1 does not expose fssai label-compliance fields'
);

select ok(
  lower(pg_get_function_result('public.published_products_v1()'::regprocedure)) not like '%country_of_origin%',
  'published_products_v1 does not expose country_of_origin label-compliance fields'
);

select ok(
  (
    select count(*)
    from pg_attribute
    where attrelid = 'public.products'::regclass
      and attname in ('fssai_licence_number', 'country_of_origin', 'label_manufacturer_details')
      and not attisdropped
  ) = 3,
  'Point37 label-compliance bundle exposes exactly three governed columns on products'
);

select * from finish();
rollback;
