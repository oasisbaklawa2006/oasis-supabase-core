-- Buyer carton packing-profile projection v1 (contract_version 1).
--
-- PROPOSAL for review. Not applied anywhere. Assigned owner: Core (Mission Control assignment required before merge).
-- Specification: oasis-baklawa docs/carton-builder/CORE_PACKING_PROFILE_CONTRACT_SPEC.md
--
-- Authority model (no competing master):
--   * Who may read: public.customer_buyer_eligible_company_id() (approved, non-frozen, non-staff buyer company).
--   * Which products are orderable: public.buyer_product_prices_v1() (published + approved B2B price). Prices, GST, MOQ and
--     increments stay there and in customer_validate_order_quantity_v1(); nothing here duplicates or overrides them.
--   * What is new: packing facts that exist nowhere governed today (packing group, slots per ordered unit, carton configurations).
-- Governance tables hold approval metadata and evidence references; buyers can read neither (RLS enabled, no policies, no grants).
-- Rollback: see supabase/rollback/20261113130000_buyer_carton_packing_profile_projection_v1_down.sql.

create table if not exists public.carton_configurations (
  id uuid primary key default gen_random_uuid(),
  config_id text not null check (btrim(config_id) <> ''),
  config_version integer not null check (config_version >= 1),
  label text not null check (btrim(label) <> ''),
  family text not null check (btrim(family) <> ''),
  capacity_slots integer not null check (capacity_slots >= 1),
  inner_pack text not null check (inner_pack in ('tray', 'box')),
  slot_columns integer check (slot_columns >= 1),
  slot_rows integer check (slot_rows >= 1),
  eligible_packing_groups text[] not null default '{}',
  mixable_group_sets jsonb not null default '[]'::jsonb check (jsonb_typeof(mixable_group_sets) = 'array'),
  visual_asset_keys jsonb check (visual_asset_keys is null or jsonb_typeof(visual_asset_keys) = 'object'),
  asset_status text not null default 'missing' check (asset_status in ('approved', 'pending', 'missing')),
  effective_from timestamptz,
  effective_until timestamptz,
  approval_status text not null default 'draft' check (approval_status in ('draft', 'pending', 'approved', 'rejected', 'retired')),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  evidence_ref text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint carton_configurations_version_key unique (config_id, config_version),
  constraint carton_configurations_grid_ck check (
    (slot_columns is null and slot_rows is null) or (slot_columns is not null and slot_rows is not null and slot_columns * slot_rows = capacity_slots)),
  constraint carton_configurations_window_ck check (effective_from is null or effective_until is null or effective_until > effective_from),
  constraint carton_configurations_approved_ck check (approval_status <> 'approved' or (approved_by is not null and approved_at is not null and evidence_ref is not null))
);

create table if not exists public.product_packing_profiles (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id),
  variant_id uuid check (variant_id is null),            -- reserved: draft lines carry product_id only
  packing_group text not null check (btrim(packing_group) <> ''),
  conversion_basis text not null default 'slot_unit' check (conversion_basis in ('slot_unit', 'fixed_ratio')),
  slots_per_unit integer check (slots_per_unit >= 1),
  ordered_units_per_slot numeric check (ordered_units_per_slot > 0 and ordered_units_per_slot < 'Infinity'::numeric),
  commercial_uom text not null check (btrim(commercial_uom) <> ''),
  carton_config_ids text[] not null check (cardinality(carton_config_ids) >= 1),
  requires_separate_carton boolean not null default false,
  mix_allowed boolean not null default true,
  full_carton_required boolean not null default true,
  profile_version integer not null check (profile_version >= 1),
  effective_from timestamptz,
  effective_until timestamptz,
  approval_status text not null default 'draft' check (approval_status in ('draft', 'pending', 'approved', 'rejected', 'retired')),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  evidence_ref text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_packing_profiles_version_key unique (product_id, profile_version),
  constraint product_packing_profiles_separate_ck check (not (requires_separate_carton and mix_allowed)),
  constraint product_packing_profiles_basis_ck check (
    (conversion_basis = 'slot_unit' and slots_per_unit is not null) or (conversion_basis = 'fixed_ratio' and ordered_units_per_slot is not null)),
  constraint product_packing_profiles_window_ck check (effective_from is null or effective_until is null or effective_until > effective_from),
  constraint product_packing_profiles_approved_ck check (approval_status <> 'approved' or (approved_by is not null and approved_at is not null and evidence_ref is not null))
);

create index if not exists product_packing_profiles_product_idx on public.product_packing_profiles (product_id, profile_version desc);

alter table public.carton_configurations enable row level security;
alter table public.product_packing_profiles enable row level security;
alter table public.carton_configurations force row level security;
alter table public.product_packing_profiles force row level security;
revoke all on public.carton_configurations from public, anon, authenticated, service_role;
revoke all on public.product_packing_profiles from public, anon, authenticated, service_role;
grant select, insert, update on public.carton_configurations to service_role;
grant select, insert, update on public.product_packing_profiles to service_role;
-- Deliberately no policies: authenticated users read only through the two projections below.

-- Approval state machine and immutability. Allowed: draft -> pending|approved|rejected; pending -> draft|approved|rejected; rejected -> draft|pending;
-- approved -> retired. Approved rows are immutable (a change is a new version) apart from retirement; retired rows are frozen for good.
create or replace function public.protect_approved_carton_packing_rows_v1()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare o jsonb; n jsonb;
begin
  if tg_op = 'DELETE' then
    if old.approval_status in ('approved', 'retired') then raise exception 'approved or retired packing rows cannot be deleted; retire and add a new version' using errcode = '23514'; end if;
    return old;
  end if;
  if old.approval_status = 'retired' then raise exception 'retired packing rows are frozen' using errcode = '23514'; end if;
  if new.approval_status is distinct from old.approval_status and not (
       (old.approval_status = 'draft' and new.approval_status in ('pending', 'approved', 'rejected'))
    or (old.approval_status = 'pending' and new.approval_status in ('draft', 'approved', 'rejected'))
    or (old.approval_status = 'rejected' and new.approval_status in ('draft', 'pending'))
    or (old.approval_status = 'approved' and new.approval_status = 'retired')) then
    raise exception 'illegal approval transition % -> %', old.approval_status, new.approval_status using errcode = '23514';
  end if;
  if old.approval_status = 'approved' then
    o := to_jsonb(old) - 'approval_status' - 'updated_at';
    n := to_jsonb(new) - 'approval_status' - 'updated_at';
    if o is distinct from n then
      raise exception 'approved packing rows are immutable; retire and add a new version' using errcode = '23514';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger carton_configurations_protect_v1 before update or delete on public.carton_configurations
  for each row execute function public.protect_approved_carton_packing_rows_v1();
create trigger product_packing_profiles_protect_v1 before update or delete on public.product_packing_profiles
  for each row execute function public.protect_approved_carton_packing_rows_v1();

-- Every group named in a mixable set must be eligible; NULL array elements must not make validation pass.
create or replace function public.validate_carton_configuration_groups_v1()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare s jsonb; g jsonb;
begin
  for s in select * from jsonb_array_elements(new.mixable_group_sets) loop
    if jsonb_typeof(s) <> 'array' then raise exception 'mixable_group_sets must be an array of arrays' using errcode = '23514'; end if;
    for g in select * from jsonb_array_elements(s) loop
      if jsonb_typeof(g) <> 'string' or ((g #>> '{}') = any (new.eligible_packing_groups)) is not true then
        raise exception 'mixable group % is not an eligible packing group', g using errcode = '23514';
      end if;
    end loop;
  end loop;
  return new;
end $$;
create trigger carton_configurations_groups_v1 before insert or update on public.carton_configurations
  for each row execute function public.validate_carton_configuration_groups_v1();

-- A profile can be approved only for configurations with an approved version, never retired-only (text[] cannot carry a foreign key).
create or replace function public.validate_profile_config_refs_v1()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare x text;
begin
  if new.approval_status = 'approved' then
    foreach x in array new.carton_config_ids loop
      if not exists (select 1 from public.carton_configurations c where c.config_id = x and c.approval_status = 'approved') then
        raise exception 'carton config % does not exist as an approved configuration', x using errcode = '23503';
      end if;
    end loop;
  end if;
  return new;
end $$;
create trigger product_packing_profiles_refs_v1 before insert or update on public.product_packing_profiles
  for each row execute function public.validate_profile_config_refs_v1();

-- Approved, currently effective configurations: half-open window [effective_from, effective_until); highest version per config_id wins.
create or replace function public.buyer_carton_configurations_v1()
returns table (
  config_id text, config_version integer, label text, family text, capacity_slots integer, inner_pack text,
  slot_columns integer, slot_rows integer, eligible_packing_groups text[], mixable_group_sets jsonb,
  visual_asset_keys jsonb, asset_status text, effective_from timestamptz, effective_until timestamptz,
  approval_status text, contract_version integer)
language sql stable security definer set search_path = pg_catalog, public as $$
  select c.config_id, c.config_version, c.label, c.family, c.capacity_slots, c.inner_pack, c.slot_columns, c.slot_rows,
         c.eligible_packing_groups, c.mixable_group_sets,
         case when c.asset_status = 'approved' then c.visual_asset_keys end,
         c.asset_status, c.effective_from, c.effective_until, 'approved'::text, 1
  from (
    select cc.*, row_number() over (partition by cc.config_id order by cc.config_version desc) rn
    from public.carton_configurations cc
    where cc.approval_status = 'approved'
      and (cc.effective_from is null or cc.effective_from <= now())
      and (cc.effective_until is null or now() < cc.effective_until)
  ) c
  where c.rn = 1 and public.customer_buyer_eligible_company_id() is not null
  order by c.config_id;
$$;

-- Approved, effective profiles for products the caller can order now (published + approved price) whose unit equals the price unit.
create or replace function public.buyer_packing_profiles_v1()
returns table (
  product_id uuid, sku text, variant_id uuid, packing_group text, conversion_basis text, slots_per_unit integer,
  ordered_units_per_slot numeric, commercial_uom text, carton_config_ids text[], requires_separate_carton boolean,
  mix_allowed boolean, full_carton_required boolean, profile_version integer, approval_status text,
  effective_from timestamptz, effective_until timestamptz, projection_hash text, contract_version integer)
language sql stable security definer set search_path = pg_catalog, public as $$
  with buyer as (select public.customer_buyer_eligible_company_id() as company_id),
  orderable as (
    select pr.product_id, lower(btrim(pr.uom)) as uom_key
    from public.buyer_product_prices_v1() pr, buyer b where b.company_id is not null
  ),
  live_configs as (select config_id from public.buyer_carton_configurations_v1()),
  ranked as (
    select p.*, row_number() over (partition by p.product_id order by p.profile_version desc) rn
    from public.product_packing_profiles p
    where p.approval_status = 'approved'
      and (p.effective_from is null or p.effective_from <= now())
      and (p.effective_until is null or now() < p.effective_until)
  )
  select r.product_id, pp.sku, r.variant_id, r.packing_group, r.conversion_basis, r.slots_per_unit, r.ordered_units_per_slot,
         lower(btrim(r.commercial_uom)),
         array(select u.x from unnest(r.carton_config_ids) with ordinality u(x, ord) where u.x in (select config_id from live_configs) order by u.ord),
         r.requires_separate_carton, r.mix_allowed, r.full_carton_required, r.profile_version, 'approved'::text,
         r.effective_from, r.effective_until,
         md5(concat_ws('|', r.product_id, r.packing_group, r.conversion_basis, r.slots_per_unit, r.ordered_units_per_slot,
             lower(btrim(r.commercial_uom)),
             array_to_string(array(select u.x from unnest(r.carton_config_ids) with ordinality u(x, ord) where u.x in (select config_id from live_configs) order by u.ord), ','),
             r.requires_separate_carton, r.mix_allowed,
             r.full_carton_required, r.profile_version, r.effective_from, r.effective_until)),
         1
  from ranked r
  join orderable o on o.product_id = r.product_id and o.uom_key = lower(btrim(r.commercial_uom))
  join public.published_products_v1() pp on pp.product_id = r.product_id
  where r.rn = 1
    and exists (select 1 from unnest(r.carton_config_ids) x where x in (select config_id from live_configs))
  order by r.product_id;
$$;

revoke all on function public.buyer_carton_configurations_v1() from public, anon;
revoke all on function public.buyer_packing_profiles_v1() from public, anon;
grant execute on function public.buyer_carton_configurations_v1() to authenticated, service_role;
grant execute on function public.buyer_packing_profiles_v1() to authenticated, service_role;
revoke all on function public.protect_approved_carton_packing_rows_v1() from public, anon, authenticated;
revoke all on function public.validate_carton_configuration_groups_v1() from public, anon, authenticated;
revoke all on function public.validate_profile_config_refs_v1() from public, anon, authenticated;
