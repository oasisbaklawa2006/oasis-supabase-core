-- SELECT-only verification pack for the recoverable data cleanup.
-- This file is safe to run against production. It performs no writes.

with product_scores as (
  select
    p.id,
    p.sku,
    coalesce(nullif(trim(p.product_name), ''), nullif(trim(p.name), '')) as display_name,
    (
      (case when coalesce(nullif(trim(p.product_name), ''), nullif(trim(p.name), '')) is not null then 1 else 0 end) +
      (case when nullif(trim(p.sku), '') is not null then 1 else 0 end) +
      (case when coalesce(nullif(trim(p.category), ''), p.category_id::text) is not null then 1 else 0 end) +
      (case when coalesce(nullif(trim(p.short_description), ''), nullif(trim(p.description), '')) is not null then 1 else 0 end) +
      (case when coalesce(nullif(trim(p.hero_image_url), ''), nullif(trim(p.image_url), '')) is not null then 1 else 0 end) +
      (case when coalesce(p.net_weight_g, p.net_weight_grams, p.primary_pack_weight_kg, p.weight_per_box_kg) is not null then 1 else 0 end) +
      (case when coalesce(nullif(trim(p.storage_instructions), ''), nullif(trim(p.storage_type), '')) is not null then 1 else 0 end) +
      (case when coalesce(p.shelf_life_days, nullif(regexp_replace(coalesce(p.shelf_life, ''), '\D', '', 'g'), '')::int) is not null then 1 else 0 end) +
      (case when coalesce(p.price_b2b, p.price_b2b_per_pack, p.wholesale_price, p.price_wholesale, p.base_price, p.price_per_kg) is not null then 1 else 0 end) +
      (case when p.is_active and p.visible_in_catalog then 1 else 0 end)
    ) as readiness_score,
    coalesce(nullif(trim(p.hero_image_url), ''), nullif(trim(p.image_url), '')) is not null as has_image,
    coalesce(p.price_b2b, p.price_b2b_per_pack, p.wholesale_price, p.price_wholesale, p.base_price, p.price_per_kg) is not null as has_price
  from public.products p
),
product_classification as (
  select *,
    case when readiness_score >= 8 and has_image and has_price then 'keep' else 'quarantine' end as decision
  from product_scores
),
order_classification as (
  select
    o.id,
    case
      when o.is_duplicate then 'quarantine'
      when not exists (select 1 from public.order_items oi where oi.order_id = o.id)
       and not exists (select 1 from public.order_payments op where op.order_id = o.id)
       and not exists (select 1 from public.order_status_history osh where osh.order_id = o.id)
       and not exists (select 1 from public.documents d where d.order_id = o.id)
       and not exists (select 1 from public.dispatches ds where ds.order_id = o.id)
      then 'quarantine'
      else 'keep'
    end as decision
  from public.orders o
),
user_activity as (
  select
    u.id,
    (
      exists (select 1 from public.profiles p where p.id = u.id) or
      exists (select 1 from public.user_role_map urm where urm.user_id = u.id) or
      exists (select 1 from public.b2b_applications b where b.user_id = u.id) or
      exists (select 1 from public.delivery_addresses da where da.user_id = u.id) or
      exists (select 1 from public.support_tickets st where st.user_id = u.id) or
      exists (select 1 from public.notifications n where n.user_id = u.id) or
      exists (select 1 from public.ols_profiles_light opl where opl.user_id = u.id) or
      exists (select 1 from public.ols_scan_history osh where osh.user_id = u.id)
    ) as has_business_activity
  from auth.users u
)
select jsonb_build_object(
  'products', jsonb_build_object(
    'keep', (select count(*) from product_classification where decision = 'keep'),
    'quarantine', (select count(*) from product_classification where decision = 'quarantine')
  ),
  'orders', jsonb_build_object(
    'keep', (select count(*) from order_classification where decision = 'keep'),
    'quarantine', (select count(*) from order_classification where decision = 'quarantine')
  ),
  'users', jsonb_build_object(
    'keep', (select count(*) from user_activity where has_business_activity),
    'quarantine', (select count(*) from user_activity where not has_business_activity)
  )
) as cleanup_summary;
