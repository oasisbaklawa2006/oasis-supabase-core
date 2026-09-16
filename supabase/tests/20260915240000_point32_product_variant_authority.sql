-- Contract for 20260915240000_point32_product_variant_authority.sql
begin;
select plan(12);

select has_column(
  'public', 'products', 'basis_product_id',
  'products exposes canonical Point32 basis parent'
);

select col_type_is(
  'public', 'products', 'basis_product_id', 'uuid',
  'basis_product_id is uuid'
);

select has_table(
  'public', 'product_variants',
  'canonical product_variants table exists'
);

select columns_are(
  'public', 'product_variants',
  array['id','product_id','basis_product_id','variant_key','basis_sku','sku','created_at','updated_at'],
  'product_variants exposes only the canonical identity graph columns'
);

select has_index(
  'public', 'product_variants', 'product_variants_product_unique',
  'each sellable product row can have at most one canonical variant identity'
);

select has_index(
  'public', 'product_variants', 'product_variants_basis_variant_key_unique',
  'variant_key is deterministic and unique within a basis product'
);

select has_trigger(
  'public', 'product_variants', 'trg_enforce_product_variant_identity_v1',
  'variant identity trigger is installed'
);

select has_function(
  'public', 'enforce_product_variant_identity_v1', array[]::text[],
  'variant identity enforcement function exists'
);

select function_privs_are(
  'public', 'enforce_product_variant_identity_v1', array[]::text[],
  'authenticated', array[]::text[],
  'authenticated callers cannot invoke the trigger function directly'
);

select policies_are(
  'public', 'product_variants',
  array['Public read product variants','Team write product variants'],
  'product_variants has explicit public-read/team-write policy boundary'
);

select table_privs_are(
  'public', 'product_variants', 'anon', array['SELECT'],
  'anonymous catalogue readers are read-only'
);

select table_privs_are(
  'public', 'product_variants', 'authenticated', array['SELECT','INSERT','UPDATE','DELETE'],
  'authenticated writes remain RLS-governed by team membership'
);

select * from finish();
rollback;
