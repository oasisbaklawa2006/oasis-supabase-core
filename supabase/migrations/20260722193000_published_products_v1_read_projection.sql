-- Customer-safe, read-only product publication contract.
--
-- Publication rule v1:
--   products.is_active = true
--   products.visible_in_catalog = true
--   products.is_catalogue_ready = true
--
-- Deliberately excluded from this contract:
--   all pricing and cost fields
--   MOQ and carton rules
--   operational notes
--   internal approval metadata
--   unpublished AI Studio draft copy
--
-- This is an RPC projection rather than a public view because the underlying
-- products table currently has broad authenticated privileges and no anonymous
-- row policy. The SECURITY DEFINER boundary exposes only the declared columns.

create or replace function public.published_products_v1()
returns table (
  product_id uuid,
  sku text,
  product_name text,
  short_description text,
  long_description text,
  category text,
  subcategory text,
  hero_image_url text,
  pack_size text,
  storage_type text,
  shelf_life text,
  shelf_life_days integer,
  dietary_tags text[],
  allergen_warnings text,
  primary_uom text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select
    p.id as product_id,
    p.sku,
    coalesce(nullif(btrim(p.product_name), ''), p.name) as product_name,
    nullif(btrim(p.short_description), '') as short_description,
    nullif(btrim(p.description), '') as long_description,
    p.category,
    coalesce(nullif(btrim(p.subcategory), ''), nullif(btrim(p.sub_category), '')) as subcategory,
    coalesce(nullif(btrim(p.hero_image_url), ''), nullif(btrim(p.image_url), '')) as hero_image_url,
    p.pack_size,
    p.storage_type,
    p.shelf_life,
    p.shelf_life_days,
    p.dietary_tags,
    p.allergen_warnings,
    coalesce(nullif(btrim(p.primary_uom), ''), nullif(btrim(p.uom), '')) as primary_uom,
    p.created_at
  from public.products p
  where p.is_active is true
    and p.visible_in_catalog is true
    and p.is_catalogue_ready is true
    and nullif(btrim(p.sku), '') is not null
    and coalesce(nullif(btrim(p.product_name), ''), nullif(btrim(p.name), '')) is not null
  order by coalesce(nullif(btrim(p.product_name), ''), p.name), p.id;
$$;

comment on function public.published_products_v1() is
  'Customer-safe product catalogue projection v1. Returns only active, visible, catalogue-ready products and excludes pricing, cost, MOQ, operational and draft-only fields.';

revoke all on function public.published_products_v1() from public;
grant execute on function public.published_products_v1() to anon, authenticated, service_role;
