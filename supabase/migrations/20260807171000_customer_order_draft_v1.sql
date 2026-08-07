-- Tranche C: persistent buyer-owned customer order draft domain.
-- Does NOT reuse internal sales_order_drafts (WhatsApp/operator inbox).
-- Company ownership derives exclusively from customer_buyer_eligible_company_id().

-- ══════════════════════════════════════════════════════════════════════
-- Schema
-- ══════════════════════════════════════════════════════════════════════

create table if not exists public.customer_order_drafts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  created_by uuid not null references auth.users(id),
  status text not null default 'active'
    check (status in ('active', 'promoted', 'cleared')),
  promoted_order_id uuid references public.orders(id),
  readiness_status text not null default 'not_ready'
    check (readiness_status in ('not_ready', 'ready')),
  readiness_issues jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.customer_order_drafts is
  'Buyer-app persistent order draft — one active draft per company; mutations via governed RPCs only.';

create unique index if not exists uq_customer_order_drafts_one_active_per_company
  on public.customer_order_drafts (company_id)
  where status = 'active';

create table if not exists public.customer_order_draft_lines (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references public.customer_order_drafts(id) on delete cascade,
  product_id uuid not null references public.products(id),
  quantity numeric not null check (quantity > 0),
  unit_price_snapshot numeric not null,
  currency_snapshot text not null default 'INR',
  uom_snapshot text,
  gst_rate_snapshot numeric,
  tax_inclusive_snapshot boolean not null default false,
  minimum_order_quantity_snapshot numeric,
  minimum_order_uom_snapshot text,
  order_increment_snapshot numeric,
  order_increment_uom_snapshot text,
  min_carton_qty_snapshot numeric,
  sku_snapshot text,
  product_name_snapshot text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_customer_order_draft_lines_one_product_per_draft unique (draft_id, product_id)
);

comment on table public.customer_order_draft_lines is
  'Lines for customer_order_drafts. Pricing/MOQ snapshots are UX/audit; checkout re-resolves authority.';

create table if not exists public.customer_order_draft_audit_log (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid references public.customer_order_drafts(id) on delete set null,
  company_id uuid not null references public.companies(id),
  actor_id uuid references auth.users(id),
  action text not null
    check (action in ('CREATE', 'ADD_LINE', 'UPDATE_LINE', 'REMOVE_LINE', 'CLEAR', 'SUBMIT_ATTEMPT', 'PROMOTE')),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

comment on table public.customer_order_draft_audit_log is
  'Append-only audit trail for customer order draft mutations and checkout attempts.';

-- ══════════════════════════════════════════════════════════════════════
-- RLS: company-scoped read; no direct client writes
-- ══════════════════════════════════════════════════════════════════════

alter table public.customer_order_drafts enable row level security;
alter table public.customer_order_draft_lines enable row level security;
alter table public.customer_order_draft_audit_log enable row level security;

drop policy if exists "Customer buyers read own company drafts" on public.customer_order_drafts;
create policy "Customer buyers read own company drafts"
  on public.customer_order_drafts
  for select
  to authenticated
  using (company_id = public.customer_buyer_eligible_company_id());

drop policy if exists "Customer buyers read own company draft lines" on public.customer_order_draft_lines;
create policy "Customer buyers read own company draft lines"
  on public.customer_order_draft_lines
  for select
  to authenticated
  using (
    draft_id in (
      select d.id from public.customer_order_drafts d
      where d.company_id = public.customer_buyer_eligible_company_id()
    )
  );

drop policy if exists "Customer buyers read own company draft audit" on public.customer_order_draft_audit_log;
create policy "Customer buyers read own company draft audit"
  on public.customer_order_draft_audit_log
  for select
  to authenticated
  using (company_id = public.customer_buyer_eligible_company_id());

revoke insert, update, delete on public.customer_order_drafts from anon, authenticated;
revoke insert, update, delete on public.customer_order_draft_lines from anon, authenticated;
revoke insert, update, delete on public.customer_order_draft_audit_log from anon, authenticated;
grant select on public.customer_order_drafts to authenticated;
grant select on public.customer_order_draft_lines to authenticated;
grant select on public.customer_order_draft_audit_log to authenticated;
grant all on public.customer_order_drafts to service_role;
grant all on public.customer_order_draft_lines to service_role;
grant all on public.customer_order_draft_audit_log to service_role;

-- ══════════════════════════════════════════════════════════════════════
-- Authority helpers (server-side pricing / MOQ / availability)
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.customer_validate_order_quantity_v1(
  p_quantity numeric,
  p_minimum_order_quantity numeric,
  p_order_increment numeric,
  p_min_carton_qty numeric default null
)
returns boolean
language plpgsql
immutable
set search_path to pg_catalog, public
as $$
begin
  if p_quantity is null or p_quantity <= 0 then
    return false;
  end if;

  if p_minimum_order_quantity is not null and p_quantity < p_minimum_order_quantity then
    return false;
  end if;

  if p_order_increment is not null and p_order_increment > 0 then
    if p_minimum_order_quantity is not null then
      if (p_quantity - p_minimum_order_quantity) % p_order_increment <> 0 then
        return false;
      end if;
    elsif p_quantity % p_order_increment <> 0 then
      return false;
    end if;
  end if;

  if p_min_carton_qty is not null and p_min_carton_qty > 0
    and p_quantity % p_min_carton_qty <> 0 then
    return false;
  end if;

  return true;
end;
$$;

comment on function public.customer_validate_order_quantity_v1(numeric, numeric, numeric, numeric) is
  'Pure MOQ/increment/carton-multiple validator for customer draft/checkout quantity rules.';

revoke all on function public.customer_validate_order_quantity_v1(numeric, numeric, numeric, numeric) from public, anon, authenticated;
grant execute on function public.customer_validate_order_quantity_v1(numeric, numeric, numeric, numeric) to service_role;

create or replace function public.customer_resolve_buyer_product_authority_v1(
  p_company_id uuid,
  p_product_id uuid
)
returns table (
  product_id uuid,
  selling_price numeric,
  currency text,
  uom text,
  gst_rate numeric,
  tax_inclusive boolean,
  minimum_order_quantity numeric,
  minimum_order_uom text,
  order_increment numeric,
  order_increment_uom text,
  min_carton_qty numeric,
  sku text,
  product_name text,
  is_available boolean
)
language sql
stable
security definer
set search_path to pg_catalog, public
as $$
  with company_ctx as (
    select
      c.id as company_id,
      greatest(least(coalesce(c.discount_percentage, 0), 100), 0)::numeric as discount_percent
    from public.companies c
    where c.id = p_company_id
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
  ), ranked_prices as (
    select
      r.product_id,
      coalesce(r.calculated_price, r.base_price)::numeric as listed_price,
      r.currency,
      r.uom,
      r.gst_rate,
      coalesce(r.tax_inclusive, false) as tax_inclusive,
      row_number() over (
        order by r.valid_from desc nulls last,
                 r.approved_at desc nulls last,
                 r.updated_at desc nulls last,
                 r.id desc
      ) as rn
    from public.product_pricing_rules r
    join public.published_products_v1() pp on pp.product_id = r.product_id
    where r.product_id = p_product_id
      and lower(coalesce(r.price_channel, '')) = 'b2b'
      and lower(coalesce(r.approval_status, '')) = 'approved'
      and coalesce(r.calculated_price, r.base_price) > 0
      and (r.valid_from is null or r.valid_from <= current_date)
      and (r.valid_until is null or r.valid_until >= current_date)
  ), b2b_moq as (
    select
      m.product_id,
      case when coalesce(m.moq_applicable, true) then m.moq_value::numeric end as moq_value,
      case when coalesce(m.moq_applicable, true) then nullif(btrim(m.moq_uom), '') end as moq_uom,
      case when coalesce(m.moq_applicable, true) then m.increment_value::numeric end as increment_value,
      case when coalesce(m.moq_applicable, true) then nullif(btrim(m.increment_uom), '') end as increment_uom,
      case when coalesce(m.moq_applicable, true) then m.min_carton_qty::numeric end as min_carton_qty
    from public.product_moq_rules m
    where m.product_id = p_product_id
      and lower(coalesce(m.channel, '')) = 'b2b'
    order by m.updated_at desc nulls last, m.created_at desc nulls last, m.id desc
    limit 1
  )
  select
    p.id as product_id,
    round(rp.listed_price * (1 - cc.discount_percent / 100), 2) as selling_price,
    coalesce(nullif(btrim(rp.currency), ''), 'INR') as currency,
    rp.uom,
    rp.gst_rate,
    rp.tax_inclusive,
    coalesce(bm.moq_value, p.moq_value::numeric, p.moq_packs::numeric, p.moq::numeric) as minimum_order_quantity,
    coalesce(
      bm.moq_uom,
      nullif(btrim(p.moq_uom), ''),
      case when p.moq_packs is not null then 'pack' end,
      nullif(btrim(p.b2b_uom), ''),
      nullif(btrim(rp.uom), '')
    ) as minimum_order_uom,
    coalesce(bm.increment_value, p.increment_value::numeric, 1::numeric) as order_increment,
    coalesce(
      bm.increment_uom,
      nullif(btrim(p.increment_uom), ''),
      nullif(btrim(p.moq_uom), ''),
      nullif(btrim(p.b2b_uom), ''),
      nullif(btrim(rp.uom), '')
    ) as order_increment_uom,
    bm.min_carton_qty,
    nullif(btrim(p.sku), '') as sku,
    coalesce(nullif(btrim(p.product_name), ''), nullif(btrim(p.name), ''), 'Product') as product_name,
    (rp.product_id is not null) as is_available
  from public.products p
  cross join company_ctx cc
  left join ranked_prices rp on rp.product_id = p.id and rp.rn = 1
  left join b2b_moq bm on bm.product_id = p.id
  where p.id = p_product_id
    and cc.company_id is not null;
$$;

comment on function public.customer_resolve_buyer_product_authority_v1(uuid, uuid) is
  'Server-side single-product pricing/MOQ authority for a company. Mirrors buyer_product_prices_v1 rules.';

revoke all on function public.customer_resolve_buyer_product_authority_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function public.customer_resolve_buyer_product_authority_v1(uuid, uuid) to service_role;

-- ══════════════════════════════════════════════════════════════════════
-- Draft readiness + audit helpers (SECURITY DEFINER, trigger-only grants)
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.customer_recompute_draft_readiness_v1(p_draft_id uuid)
returns void
language plpgsql
security definer
set search_path to pg_catalog, public
as $$
declare
  v_draft public.customer_order_drafts%rowtype;
  v_issues jsonb := '[]'::jsonb;
  v_line record;
  v_auth record;
  v_ready boolean := true;
begin
  select * into v_draft from public.customer_order_drafts where id = p_draft_id for update;
  if not found then
    return;
  end if;

  if v_draft.status <> 'active' then
    update public.customer_order_drafts
    set readiness_status = 'not_ready',
        readiness_issues = jsonb_build_array(jsonb_build_object('code', 'DRAFT_NOT_ACTIVE')),
        updated_at = now()
    where id = p_draft_id;
    return;
  end if;

  if not exists (select 1 from public.customer_order_draft_lines where draft_id = p_draft_id) then
    v_issues := v_issues || jsonb_build_array(jsonb_build_object('code', 'EMPTY_DRAFT'));
    v_ready := false;
  end if;

  for v_line in
    select l.* from public.customer_order_draft_lines l where l.draft_id = p_draft_id
  loop
    select * into v_auth
    from public.customer_resolve_buyer_product_authority_v1(v_draft.company_id, v_line.product_id);

    if not coalesce(v_auth.is_available, false) then
      v_issues := v_issues || jsonb_build_array(jsonb_build_object(
        'code', 'PRODUCT_UNAVAILABLE', 'product_id', v_line.product_id));
      v_ready := false;
      continue;
    end if;

    if not public.customer_validate_order_quantity_v1(
      v_line.quantity,
      v_auth.minimum_order_quantity,
      v_auth.order_increment,
      v_auth.min_carton_qty
    ) then
      v_issues := v_issues || jsonb_build_array(jsonb_build_object(
        'code', 'QUANTITY_RULE_VIOLATION', 'product_id', v_line.product_id, 'quantity', v_line.quantity));
      v_ready := false;
    end if;
  end loop;

  update public.customer_order_drafts
  set readiness_status = case when v_ready then 'ready' else 'not_ready' end,
      readiness_issues = v_issues,
      updated_at = now()
  where id = p_draft_id;
end;
$$;

revoke all on function public.customer_recompute_draft_readiness_v1(uuid) from public, anon, authenticated;
grant execute on function public.customer_recompute_draft_readiness_v1(uuid) to service_role;

create or replace function public.customer_order_draft_audit_v1(
  p_draft_id uuid,
  p_company_id uuid,
  p_actor_id uuid,
  p_action text,
  p_detail jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path to pg_catalog, public
as $$
begin
  insert into public.customer_order_draft_audit_log (draft_id, company_id, actor_id, action, detail)
  values (p_draft_id, p_company_id, p_actor_id, p_action, coalesce(p_detail, '{}'::jsonb));
end;
$$;

revoke all on function public.customer_order_draft_audit_v1(uuid, uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.customer_order_draft_audit_v1(uuid, uuid, uuid, text, jsonb) to service_role;

-- ══════════════════════════════════════════════════════════════════════
-- Governed draft RPCs
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.get_customer_order_draft_v1()
returns table (
  draft_id uuid,
  company_id uuid,
  status text,
  readiness_status text,
  readiness_issues jsonb,
  line_id uuid,
  product_id uuid,
  quantity numeric,
  unit_price_snapshot numeric,
  currency_snapshot text,
  uom_snapshot text,
  sku_snapshot text,
  product_name_snapshot text
)
language plpgsql
security definer
set search_path to pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_company_id uuid;
  v_draft_id uuid;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required'
      using errcode = '28000';
  end if;

  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'BUYER_NOT_ELIGIBLE: approved buyer company context is required'
      using errcode = '42501';
  end if;

  select d.id into v_draft_id
  from public.customer_order_drafts d
  where d.company_id = v_company_id and d.status = 'active'
  limit 1;

  if v_draft_id is null then
    insert into public.customer_order_drafts (company_id, created_by, status)
    values (v_company_id, v_uid, 'active')
    returning id into v_draft_id;

    perform public.customer_order_draft_audit_v1(v_draft_id, v_company_id, v_uid, 'CREATE', '{}'::jsonb);
    perform public.customer_recompute_draft_readiness_v1(v_draft_id);
  end if;

  return query
  select
    d.id,
    d.company_id,
    d.status,
    d.readiness_status,
    d.readiness_issues,
    l.id,
    l.product_id,
    l.quantity,
    l.unit_price_snapshot,
    l.currency_snapshot,
    l.uom_snapshot,
    l.sku_snapshot,
    l.product_name_snapshot
  from public.customer_order_drafts d
  left join public.customer_order_draft_lines l on l.draft_id = d.id
  where d.id = v_draft_id
  order by l.created_at, l.id;
end;
$$;

revoke all on function public.get_customer_order_draft_v1() from public, anon;
grant execute on function public.get_customer_order_draft_v1() to authenticated, service_role;

create or replace function public.add_customer_order_draft_line_v1(
  p_product_id uuid,
  p_quantity numeric
)
returns table (
  draft_id uuid,
  line_id uuid,
  readiness_status text,
  readiness_issues jsonb
)
language plpgsql
security definer
set search_path to pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_company_id uuid;
  v_draft_id uuid;
  v_auth record;
  v_line_id uuid;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required' using errcode = '28000';
  end if;

  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' using errcode = '42501';
  end if;

  if p_product_id is null or p_quantity is null or p_quantity <= 0 then
    raise exception 'VALIDATION_FAILED: product_id and positive quantity are required';
  end if;

  select * into v_auth from public.customer_resolve_buyer_product_authority_v1(v_company_id, p_product_id);
  if not coalesce(v_auth.is_available, false) then
    raise exception 'PRODUCT_UNAVAILABLE: product % is not available for this buyer', p_product_id;
  end if;

  if not public.customer_validate_order_quantity_v1(
    p_quantity, v_auth.minimum_order_quantity, v_auth.order_increment, v_auth.min_carton_qty
  ) then
    raise exception 'QUANTITY_RULE_VIOLATION: quantity does not satisfy MOQ/increment/carton rules for product %', p_product_id;
  end if;

  select d.id into v_draft_id
  from public.customer_order_drafts d
  where d.company_id = v_company_id and d.status = 'active'
  for update;

  if v_draft_id is null then
    insert into public.customer_order_drafts (company_id, created_by, status)
    values (v_company_id, v_uid, 'active')
    returning id into v_draft_id;
    perform public.customer_order_draft_audit_v1(v_draft_id, v_company_id, v_uid, 'CREATE', '{}'::jsonb);
  end if;

  insert into public.customer_order_draft_lines (
    draft_id, product_id, quantity,
    unit_price_snapshot, currency_snapshot, uom_snapshot,
    gst_rate_snapshot, tax_inclusive_snapshot,
    minimum_order_quantity_snapshot, minimum_order_uom_snapshot,
    order_increment_snapshot, order_increment_uom_snapshot,
    min_carton_qty_snapshot, sku_snapshot, product_name_snapshot
  ) values (
    v_draft_id, p_product_id, p_quantity,
    v_auth.selling_price, v_auth.currency, v_auth.uom,
    v_auth.gst_rate, v_auth.tax_inclusive,
    v_auth.minimum_order_quantity, v_auth.minimum_order_uom,
    v_auth.order_increment, v_auth.order_increment_uom,
    v_auth.min_carton_qty, v_auth.sku, v_auth.product_name
  )
  on conflict on constraint uq_customer_order_draft_lines_one_product_per_draft
  do update set
    quantity = excluded.quantity,
    unit_price_snapshot = excluded.unit_price_snapshot,
    currency_snapshot = excluded.currency_snapshot,
    uom_snapshot = excluded.uom_snapshot,
    gst_rate_snapshot = excluded.gst_rate_snapshot,
    tax_inclusive_snapshot = excluded.tax_inclusive_snapshot,
    minimum_order_quantity_snapshot = excluded.minimum_order_quantity_snapshot,
    minimum_order_uom_snapshot = excluded.minimum_order_uom_snapshot,
    order_increment_snapshot = excluded.order_increment_snapshot,
    order_increment_uom_snapshot = excluded.order_increment_uom_snapshot,
    min_carton_qty_snapshot = excluded.min_carton_qty_snapshot,
    sku_snapshot = excluded.sku_snapshot,
    product_name_snapshot = excluded.product_name_snapshot,
    updated_at = now()
  returning id into v_line_id;

  perform public.customer_order_draft_audit_v1(
    v_draft_id, v_company_id, v_uid, 'ADD_LINE',
    jsonb_build_object('line_id', v_line_id, 'product_id', p_product_id, 'quantity', p_quantity));
  perform public.customer_recompute_draft_readiness_v1(v_draft_id);

  return query
  select d.id, v_line_id, d.readiness_status, d.readiness_issues
  from public.customer_order_drafts d where d.id = v_draft_id;
end;
$$;

revoke all on function public.add_customer_order_draft_line_v1(uuid, numeric) from public, anon;
grant execute on function public.add_customer_order_draft_line_v1(uuid, numeric) to authenticated, service_role;

create or replace function public.update_customer_order_draft_line_v1(
  p_line_id uuid,
  p_quantity numeric
)
returns table (
  draft_id uuid,
  line_id uuid,
  readiness_status text,
  readiness_issues jsonb
)
language plpgsql
security definer
set search_path to pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_company_id uuid;
  v_line public.customer_order_draft_lines%rowtype;
  v_auth record;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required' using errcode = '28000';
  end if;

  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' using errcode = '42501';
  end if;

  if p_line_id is null or p_quantity is null or p_quantity <= 0 then
    raise exception 'VALIDATION_FAILED: line_id and positive quantity are required';
  end if;

  select l.* into v_line
  from public.customer_order_draft_lines l
  join public.customer_order_drafts d on d.id = l.draft_id
  where l.id = p_line_id
    and d.company_id = v_company_id
    and d.status = 'active'
  for update of l;

  if not found then
    raise exception 'LINE_NOT_FOUND: draft line % is not mutable for this buyer', p_line_id using errcode = 'P0002';
  end if;

  select * into v_auth from public.customer_resolve_buyer_product_authority_v1(v_company_id, v_line.product_id);
  if not coalesce(v_auth.is_available, false) then
    raise exception 'PRODUCT_UNAVAILABLE: product % is not available for this buyer', v_line.product_id;
  end if;

  if not public.customer_validate_order_quantity_v1(
    p_quantity, v_auth.minimum_order_quantity, v_auth.order_increment, v_auth.min_carton_qty
  ) then
    raise exception 'QUANTITY_RULE_VIOLATION: quantity does not satisfy MOQ/increment/carton rules';
  end if;

  update public.customer_order_draft_lines
  set quantity = p_quantity,
      unit_price_snapshot = v_auth.selling_price,
      currency_snapshot = v_auth.currency,
      uom_snapshot = v_auth.uom,
      gst_rate_snapshot = v_auth.gst_rate,
      tax_inclusive_snapshot = v_auth.tax_inclusive,
      minimum_order_quantity_snapshot = v_auth.minimum_order_quantity,
      minimum_order_uom_snapshot = v_auth.minimum_order_uom,
      order_increment_snapshot = v_auth.order_increment,
      order_increment_uom_snapshot = v_auth.order_increment_uom,
      min_carton_qty_snapshot = v_auth.min_carton_qty,
      sku_snapshot = v_auth.sku,
      product_name_snapshot = v_auth.product_name,
      updated_at = now()
  where id = p_line_id;

  perform public.customer_order_draft_audit_v1(
    v_line.draft_id, v_company_id, v_uid, 'UPDATE_LINE',
    jsonb_build_object('line_id', p_line_id, 'quantity', p_quantity));
  perform public.customer_recompute_draft_readiness_v1(v_line.draft_id);

  return query
  select d.id, p_line_id, d.readiness_status, d.readiness_issues
  from public.customer_order_drafts d where d.id = v_line.draft_id;
end;
$$;

revoke all on function public.update_customer_order_draft_line_v1(uuid, numeric) from public, anon;
grant execute on function public.update_customer_order_draft_line_v1(uuid, numeric) to authenticated, service_role;

create or replace function public.remove_customer_order_draft_line_v1(p_line_id uuid)
returns table (
  draft_id uuid,
  readiness_status text,
  readiness_issues jsonb
)
language plpgsql
security definer
set search_path to pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_company_id uuid;
  v_line public.customer_order_draft_lines%rowtype;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required' using errcode = '28000';
  end if;

  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' using errcode = '42501';
  end if;

  select l.* into v_line
  from public.customer_order_draft_lines l
  join public.customer_order_drafts d on d.id = l.draft_id
  where l.id = p_line_id
    and d.company_id = v_company_id
    and d.status = 'active'
  for update of l;

  if not found then
    raise exception 'LINE_NOT_FOUND: draft line % is not mutable for this buyer', p_line_id using errcode = 'P0002';
  end if;

  delete from public.customer_order_draft_lines where id = p_line_id;

  perform public.customer_order_draft_audit_v1(
    v_line.draft_id, v_company_id, v_uid, 'REMOVE_LINE',
    jsonb_build_object('line_id', p_line_id, 'product_id', v_line.product_id));
  perform public.customer_recompute_draft_readiness_v1(v_line.draft_id);

  return query
  select d.id, d.readiness_status, d.readiness_issues
  from public.customer_order_drafts d where d.id = v_line.draft_id;
end;
$$;

revoke all on function public.remove_customer_order_draft_line_v1(uuid) from public, anon;
grant execute on function public.remove_customer_order_draft_line_v1(uuid) to authenticated, service_role;

create or replace function public.clear_customer_order_draft_v1()
returns table (
  draft_id uuid,
  readiness_status text,
  readiness_issues jsonb
)
language plpgsql
security definer
set search_path to pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_company_id uuid;
  v_draft_id uuid;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required' using errcode = '28000';
  end if;

  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' using errcode = '42501';
  end if;

  select d.id into v_draft_id
  from public.customer_order_drafts d
  where d.company_id = v_company_id and d.status = 'active'
  for update;

  if v_draft_id is null then
    insert into public.customer_order_drafts (company_id, created_by, status)
    values (v_company_id, v_uid, 'active')
    returning id into v_draft_id;
    perform public.customer_order_draft_audit_v1(v_draft_id, v_company_id, v_uid, 'CREATE', '{}'::jsonb);
  else
    delete from public.customer_order_draft_lines where draft_id = v_draft_id;
    perform public.customer_order_draft_audit_v1(v_draft_id, v_company_id, v_uid, 'CLEAR', '{}'::jsonb);
    perform public.customer_recompute_draft_readiness_v1(v_draft_id);
  end if;

  return query
  select d.id, d.readiness_status, d.readiness_issues
  from public.customer_order_drafts d where d.id = v_draft_id;
end;
$$;

revoke all on function public.clear_customer_order_draft_v1() from public, anon;
grant execute on function public.clear_customer_order_draft_v1() to authenticated, service_role;
