-- Point32 canonical product / variant hierarchy authority.
-- Repository-only migration: production release remains separately governed.
begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.products
  add column if not exists basis_product_id uuid;

alter table public.products
  drop constraint if exists products_basis_product_id_fkey;
alter table public.products
  add constraint products_basis_product_id_fkey
  foreign key (basis_product_id)
  references public.products(id)
  on delete set null
  not valid;

alter table public.products
  drop constraint if exists products_basis_product_not_self_check;
alter table public.products
  add constraint products_basis_product_not_self_check
  check (basis_product_id is null or basis_product_id <> id)
  not valid;

comment on column public.products.basis_product_id is
  'Point32 canonical sellable-variant parent. Distinct from BOM/hamper composition and packaging hierarchy.';

do $point32_upgrade$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'product_variants'
      and column_name = 'variant_name'
  ) then
    alter table public.product_variants
      rename to product_variants_legacy_pre_point32;

    comment on table public.product_variants_legacy_pre_point32 is
      'Archived legacy product_variants shape retained for read-only reconciliation; Point32 authority uses public.product_variants.';
  end if;
end
$point32_upgrade$;

create table if not exists public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  basis_product_id uuid not null references public.products(id) on delete restrict,
  variant_key text not null,
  basis_sku text not null,
  sku text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_variants_product_unique unique (product_id),
  constraint product_variants_basis_variant_key_unique unique (basis_product_id, variant_key),
  constraint product_variants_basis_sku_unique unique (basis_product_id, sku),
  constraint product_variants_not_self check (product_id <> basis_product_id),
  constraint product_variants_variant_key_nonblank check (btrim(variant_key) <> ''),
  constraint product_variants_basis_sku_nonblank check (btrim(basis_sku) <> ''),
  constraint product_variants_sku_nonblank check (btrim(sku) <> '')
);

comment on table public.product_variants is
  'Point32 canonical explicit sellable-SKU variant graph. product_id is the variant SKU row; basis_product_id is its canonical basis product.';
comment on column public.product_variants.variant_key is
  'Deterministic operator-reviewed variant key, unique within one basis product.';

create or replace function public.enforce_product_variant_identity_v1()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_basis_sku text;
  v_variant_sku text;
  v_declared_basis uuid;
begin
  select p.sku
    into v_basis_sku
  from public.products p
  where p.id = new.basis_product_id;

  select p.sku, p.basis_product_id
    into v_variant_sku, v_declared_basis
  from public.products p
  where p.id = new.product_id;

  if v_basis_sku is null or btrim(v_basis_sku) = '' then
    raise exception using errcode = '23514', message = 'POINT32_BASIS_SKU_REQUIRED';
  end if;
  if v_variant_sku is null or btrim(v_variant_sku) = '' then
    raise exception using errcode = '23514', message = 'POINT32_VARIANT_SKU_REQUIRED';
  end if;
  if v_declared_basis is distinct from new.basis_product_id then
    raise exception using errcode = '23514', message = 'POINT32_BASIS_PRODUCT_MISMATCH';
  end if;
  if new.basis_sku is distinct from v_basis_sku then
    raise exception using errcode = '23514', message = 'POINT32_BASIS_SKU_MISMATCH';
  end if;
  if new.sku is distinct from v_variant_sku then
    raise exception using errcode = '23514', message = 'POINT32_VARIANT_SKU_MISMATCH';
  end if;

  new.variant_key := btrim(new.variant_key);
  new.basis_sku := v_basis_sku;
  new.sku := v_variant_sku;
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.enforce_product_variant_identity_v1() from public, anon, authenticated;

drop trigger if exists trg_enforce_product_variant_identity_v1 on public.product_variants;
create trigger trg_enforce_product_variant_identity_v1
before insert or update on public.product_variants
for each row execute function public.enforce_product_variant_identity_v1();

create index if not exists idx_product_variants_basis_product
  on public.product_variants (basis_product_id);
create index if not exists idx_products_basis_product_id
  on public.products (basis_product_id)
  where basis_product_id is not null;

create or replace function public.enforce_product_point32_identity_immutable_v1()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.sku is distinct from old.sku
     or new.basis_product_id is distinct from old.basis_product_id then
    if exists (
      select 1
      from public.product_variants pv
      where pv.product_id = old.id
         or pv.basis_product_id = old.id
    ) then
      raise exception using errcode = '23514', message = 'POINT32_PRODUCT_IDENTITY_LOCKED';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_product_point32_identity_immutable_v1() from public, anon, authenticated;

drop trigger if exists trg_enforce_product_point32_identity_immutable_v1 on public.products;
create trigger trg_enforce_product_point32_identity_immutable_v1
before update on public.products
for each row execute function public.enforce_product_point32_identity_immutable_v1();

alter table public.product_variants enable row level security;

drop policy if exists "Public read product variants" on public.product_variants;
drop policy if exists "Team write product variants" on public.product_variants;
drop policy if exists "OASIS_AUTHENTICATED_FULL_ACCESS" on public.product_variants;

create policy "Authenticated read product variants"
on public.product_variants
for select
to authenticated
using (true);

create policy "Admins insert product variants"
on public.product_variants
for insert
to authenticated
with check (public.is_admin());

create policy "Admins update product variants"
on public.product_variants
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Admins delete product variants"
on public.product_variants
for delete
to authenticated
using (public.is_admin());

revoke all on table public.product_variants from public, anon, authenticated;
grant select on table public.product_variants to anon, authenticated;
grant insert, update, delete on table public.product_variants to authenticated;
grant all on table public.product_variants to service_role;

commit;
