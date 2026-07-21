-- Contract checks for buyer_product_prices_v1().
-- Run with a test transaction and representative eligible/ineligible auth identities.

-- Privilege boundary.
select has_function_privilege('anon', 'public.buyer_product_prices_v1()', 'EXECUTE') is false;
select has_function_privilege('authenticated', 'public.buyer_product_prices_v1()', 'EXECUTE') is true;
select has_function_privilege('public', 'public.buyer_product_prices_v1()', 'EXECUTE') is false;

-- Function hardening.
select prosecdef is true
from pg_proc
where oid = 'public.buyer_product_prices_v1()'::regprocedure;

-- Anonymous/no JWT identity must receive no rows.
select count(*) = 0 from public.buyer_product_prices_v1();

-- Under an eligible buyer JWT identity, assert one row per product and complete safe pricing rules.
select count(*) = count(distinct product_id)
from public.buyer_product_prices_v1();

select count(*) = 0
from public.buyer_product_prices_v1()
where selling_price <= 0
   or currency is null
   or btrim(currency) = ''
   or minimum_order_quantity is null
   or minimum_order_quantity <= 0
   or order_increment is null
   or order_increment <= 0;

select count(*) = 0
from public.buyer_product_prices_v1() bp
left join public.published_products_v1() pp on pp.product_id = bp.product_id
where pp.product_id is null;

-- Internal pricing, approval, notes and cost fields must not appear in the return contract.
select count(*) = 0
from information_schema.routine_columns
where specific_schema = 'public'
  and routine_name = 'buyer_product_prices_v1'
  and column_name in (
    'base_price', 'calculated_price', 'approval_status', 'approved_by',
    'pricing_notes', 'notes', 'cost_per_kg', 'cost_per_pc'
  );
