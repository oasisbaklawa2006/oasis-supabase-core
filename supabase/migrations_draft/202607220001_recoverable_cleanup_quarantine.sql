-- DRAFT ONLY. Apply only after candidate verification and backup checks pass.
-- Purpose: create recoverable snapshots and quarantine low-readiness records.
-- This migration intentionally performs no hard deletes.

begin;

create schema if not exists cleanup_archive;
revoke all on schema cleanup_archive from public, anon, authenticated;

create table if not exists cleanup_archive.product_snapshot_20260722
(like public.products including all);

create table if not exists cleanup_archive.order_snapshot_20260722
(like public.orders including all);

-- Deliberately excludes password hashes, recovery tokens, confirmation tokens,
-- refresh/session data, and other authentication secrets.
create table if not exists cleanup_archive.auth_user_snapshot_20260722 (
  id uuid primary key,
  email text,
  phone text,
  created_at timestamptz,
  updated_at timestamptz,
  last_sign_in_at timestamptz,
  email_confirmed_at timestamptz,
  phone_confirmed_at timestamptz,
  banned_until timestamptz,
  deleted_at timestamptz,
  is_sso_user boolean,
  is_anonymous boolean,
  raw_app_meta_data jsonb,
  raw_user_meta_data jsonb
);

with product_scores as (
  select
    p.*,
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
), candidates as (
  select * from product_scores
  where not (readiness_score >= 8 and has_image and has_price)
)
insert into cleanup_archive.product_snapshot_20260722
select p.* from public.products p
join candidates c on c.id = p.id
on conflict do nothing;

update public.products p
set is_active = false,
    visible_in_catalog = false
where exists (
  select 1 from cleanup_archive.product_snapshot_20260722 a where a.id = p.id
);

with order_candidates as (
  select o.*
  from public.orders o
  where o.is_duplicate
     or (
       not exists (select 1 from public.order_items oi where oi.order_id = o.id)
       and not exists (select 1 from public.order_payments op where op.order_id = o.id)
       and not exists (select 1 from public.order_status_history osh where osh.order_id = o.id)
       and not exists (select 1 from public.documents d where d.order_id = o.id)
       and not exists (select 1 from public.dispatches ds where ds.order_id = o.id)
     )
)
insert into cleanup_archive.order_snapshot_20260722
select * from order_candidates
on conflict do nothing;

-- Orders are only snapshotted in this tranche.

with user_candidates as (
  select u.*
  from auth.users u
  where not (
    exists (select 1 from public.profiles p where p.id = u.id) or
    exists (select 1 from public.user_role_map urm where urm.user_id = u.id) or
    exists (select 1 from public.b2b_applications b where b.user_id = u.id) or
    exists (select 1 from public.delivery_addresses da where da.user_id = u.id) or
    exists (select 1 from public.support_tickets st where st.user_id = u.id) or
    exists (select 1 from public.notifications n where n.user_id = u.id) or
    exists (select 1 from public.ols_profiles_light opl where opl.user_id = u.id) or
    exists (select 1 from public.ols_scan_history osh where osh.user_id = u.id)
  )
)
insert into cleanup_archive.auth_user_snapshot_20260722 (
  id, email, phone, created_at, updated_at, last_sign_in_at,
  email_confirmed_at, phone_confirmed_at, banned_until, deleted_at,
  is_sso_user, is_anonymous, raw_app_meta_data, raw_user_meta_data
)
select
  id, email, phone, created_at, updated_at, last_sign_in_at,
  email_confirmed_at, phone_confirmed_at, banned_until, deleted_at,
  is_sso_user, is_anonymous, raw_app_meta_data, raw_user_meta_data
from user_candidates
on conflict (id) do nothing;

-- Users are snapshotted only. Auth deletion/ban is intentionally deferred.

commit;
