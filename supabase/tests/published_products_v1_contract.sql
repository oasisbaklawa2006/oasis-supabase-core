-- Read-only verification for public.published_products_v1().
-- Run after applying the migration in a non-production database.

begin;

-- Contract exists.
select to_regprocedure('public.published_products_v1()') is not null
  as function_exists;

-- Contract returns only strictly publishable products.
select not exists (
  select 1
  from public.published_products_v1() c
  left join public.products p on p.id = c.product_id
  where p.id is null
     or p.is_active is not true
     or p.visible_in_catalog is not true
     or p.is_catalogue_ready is not true
) as only_strictly_publishable_rows;

-- Mandatory identifiers are never blank.
select not exists (
  select 1
  from public.published_products_v1()
  where product_id is null
     or nullif(btrim(sku), '') is null
     or nullif(btrim(product_name), '') is null
) as mandatory_identifiers_present;

-- No duplicate product rows.
select not exists (
  select product_id
  from public.published_products_v1()
  group by product_id
  having count(*) > 1
) as one_row_per_product;

-- Current production data was expected to yield 10 rows during the July 2026
-- read-only audit. This is informational only because publication flags evolve.
select count(*) as current_publishable_count
from public.published_products_v1();

rollback;
