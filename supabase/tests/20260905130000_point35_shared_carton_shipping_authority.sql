-- Contract for migration 20260905130000_point35_shared_carton_shipping_authority.sql
begin;

select plan(17);

select has_column(
  'public', 'products', 'carton_dimensions_cm',
  'products.carton_dimensions_cm is canonical Core shipping-dimension authority'
);

select has_column(
  'public', 'products', 'cbm',
  'products.cbm is canonical Core shipping-volume authority'
);

select has_column(
  'public', 'products', 'gross_weight_kg',
  'products.gross_weight_kg is reused canonical gross-weight authority'
);

select col_type_is(
  'public', 'products', 'carton_dimensions_cm', 'text',
  'carton_dimensions_cm is text'
);

select col_type_is(
  'public', 'products', 'cbm', 'numeric',
  'cbm is numeric'
);

select col_type_is(
  'public', 'products', 'gross_weight_kg', 'numeric',
  'gross_weight_kg remains numeric'
);

select col_is_null(
  'public', 'products', 'carton_dimensions_cm',
  'carton_dimensions_cm is nullable for backward compatibility'
);

select col_is_null(
  'public', 'products', 'cbm',
  'cbm is nullable for backward compatibility'
);

select ok(
  exists(
    select 1
    from pg_constraint
    where conname = 'products_cbm_nonnegative_check'
      and conrelid = 'public.products'::regclass
  ),
  'cbm has non-negative check constraint'
);

select ok(
  position('master-carton' in lower(coalesce(col_description('public.products'::regclass, (
    select attnum from pg_attribute
    where attrelid = 'public.products'::regclass and attname = 'gross_weight_kg'
  )), ''))) > 0,
  'gross_weight_kg comment documents master-carton authority'
);

select ok(
  position('master-carton' in lower(coalesce(col_description('public.products'::regclass, (
    select attnum from pg_attribute
    where attrelid = 'public.products'::regclass and attname = 'carton_dimensions_cm'
  )), ''))) > 0,
  'carton_dimensions_cm comment documents master-carton authority'
);

select ok(
  position('cubic metres' in lower(coalesce(col_description('public.products'::regclass, (
    select attnum from pg_attribute
    where attrelid = 'public.products'::regclass and attname = 'cbm'
  )), ''))) > 0,
  'cbm comment documents cubic-metre authority'
);

select ok(
  (
    select count(*) = 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'products'
      and column_name = 'gross_weight_kg'
  ),
  'gross_weight_kg is not duplicated on public.products'
);

select has_column(
  'public', 'products', 'dimension_l_cm',
  'dimension_l_cm remains for structured dimension compatibility'
);

select has_column(
  'public', 'products', 'product_dimensions_cm',
  'product_dimensions_cm remains for product-dimension compatibility'
);

select has_column(
  'public', 'products', 'gross_weight_g',
  'gross_weight_g remains for gram-precision weight compatibility'
);

select ok(
  (
    select count(*)
    from pg_attribute
    where attrelid = 'public.products'::regclass
      and attname in ('carton_dimensions_cm', 'cbm', 'gross_weight_kg')
      and not attisdropped
  ) = 3,
  'Point35 shipping authority exposes exactly three governed columns on products'
);

select * from finish();
rollback;
