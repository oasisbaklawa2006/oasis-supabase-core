-- Contract for migration 20260722193000_published_products_v1_read_projection.sql

begin;

select plan(8);

select has_function('public', 'published_products_v1', array[]::text[], 'published_products_v1 exists');
select ok((select prosecdef from pg_proc where oid = 'public.published_products_v1()'::regprocedure), 'published_products_v1 is SECURITY DEFINER');
select ok((select proconfig @> array['search_path=pg_catalog, public'] from pg_proc where oid = 'public.published_products_v1()'::regprocedure), 'published_products_v1 has fixed search_path');
select ok(has_function_privilege('anon', 'public.published_products_v1()', 'EXECUTE'), 'anon can execute published_products_v1');
select ok(has_function_privilege('authenticated', 'public.published_products_v1()', 'EXECUTE'), 'authenticated can execute published_products_v1');
select ok(not has_function_privilege('public', 'public.published_products_v1()', 'EXECUTE'), 'PUBLIC cannot execute published_products_v1');
select ok(not exists (
  select 1
  from public.published_products_v1() c
  left join public.products p on p.id = c.product_id
  where p.id is null
     or p.is_active is not true
     or p.visible_in_catalog is not true
     or p.is_catalogue_ready is not true
     or c.product_id is null
     or nullif(btrim(c.sku), '') is null
     or nullif(btrim(c.product_name), '') is null
), 'projection returns only strictly publishable rows with mandatory identifiers');
select ok(not exists (
  select product_id
  from public.published_products_v1()
  group by product_id
  having count(*) > 1
), 'projection returns at most one row per product');

select * from finish();
rollback;
