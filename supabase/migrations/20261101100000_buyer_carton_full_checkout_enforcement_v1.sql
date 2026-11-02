-- Core carton enforcement v1: mandatory full shipping cartons at the order-line chokepoint.
-- Depends on 20261101090000 (carton_configurations / product_packing_profiles). Default OFF (fail-closed once enabled).
-- One chokepoint: a DEFERRABLE INITIALLY DEFERRED constraint trigger on public.order_items evaluates the final state of the
-- order at COMMIT, so it covers submit_customer_order_v1, amend_sales_order_commercial_v1, WhatsApp promotion
-- (promote_sales_order_draft_to_order_governed_v1) and any other writer, without rewriting those functions.
-- Governed, immutable exceptions allow staff / WhatsApp orders that Operations explicitly approves.

-- Hard precondition: this migration reads the governance tables created by 20261101090000 (#471). Enforcement ships OFF, but if it were ever
-- switched on without those tables every order write would fail. Refuse to apply out of order instead of relying on file-name ordering alone.
do $$
begin
  if to_regclass('public.carton_configurations') is null or to_regclass('public.product_packing_profiles') is null then
    raise exception 'MIGRATION_ORDER_VIOLATION: 20261101090000_buyer_carton_packing_profile_projection_v1 must be applied before 20261101100000 (carton_configurations / product_packing_profiles missing)';
  end if;
end $$;

create table public.carton_enforcement_settings (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  enforced_from timestamptz,                 -- set by the guard when enabled turns true; orders created earlier are legacy for the dispatch gate
  updated_at timestamptz not null default now()
);
insert into public.carton_enforcement_settings (singleton, enabled) values (true, false);

create table public.carton_enforcement_exceptions (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in ('order', 'sales_order_draft')),
  ref_id uuid not null,
  reason text not null check (char_length(btrim(reason)) >= 15),
  granted_by uuid not null,
  granted_at timestamptz not null default now(),
  unique (scope, ref_id)
);

alter table public.carton_enforcement_settings enable row level security;
alter table public.carton_enforcement_settings force row level security;
alter table public.carton_enforcement_exceptions enable row level security;
alter table public.carton_enforcement_exceptions force row level security;
revoke all on public.carton_enforcement_settings, public.carton_enforcement_exceptions from public, anon, authenticated, service_role;
grant select, update on public.carton_enforcement_settings to service_role;
grant select, insert on public.carton_enforcement_exceptions to service_role;

create or replace function public.protect_carton_enforcement_audit_v1() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
begin
  if tg_table_name = 'carton_enforcement_exceptions' then
    raise exception 'carton enforcement exceptions are immutable audit records' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then raise exception 'the enforcement settings row cannot be deleted' using errcode = '23514'; end if;
  new.singleton := true; new.updated_at := now();
  if new.enabled and not old.enabled then new.enforced_from := now(); end if;
  return new;
end $$;
create trigger trg_carton_exceptions_immutable before update or delete on public.carton_enforcement_exceptions
  for each row execute function public.protect_carton_enforcement_audit_v1();
create trigger trg_carton_settings_guard before update or delete on public.carton_enforcement_settings
  for each row execute function public.protect_carton_enforcement_audit_v1();

-- Returns a jsonb array of violations for the order's current lines ([] = every shipping carton is complete).
create or replace function public.evaluate_order_carton_completeness_v1(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v jsonb := '[]'::jsonb; groups jsonb := '{}'::jsonb; r record; cfg record; price_uom text;
  slots numeric; gkey text; gentry record;
begin
  for r in
    with ln as (select oi.product_id, sum(oi.quantity) as qty from public.order_items oi where oi.order_id = p_order_id group by oi.product_id)
    select ln.product_id, ln.qty, pf.id as profile_id, pf.packing_group, pf.conversion_basis, pf.slots_per_unit, pf.ordered_units_per_slot,
           pf.commercial_uom, pf.carton_config_ids, pf.requires_separate_carton, pf.mix_allowed, pf.full_carton_required
      from ln
      left join lateral (
        select p.* from public.product_packing_profiles p
         where p.product_id = ln.product_id and p.variant_id is null and p.approval_status = 'approved'
           and (p.effective_from is null or p.effective_from <= now()) and (p.effective_until is null or now() < p.effective_until)
         order by p.profile_version desc limit 1) pf on true
  loop
    if r.profile_id is null then
      v := v || jsonb_build_object('code', 'CARTON_PROFILE_MISSING', 'product_id', r.product_id); continue;
    end if;
    select pr.uom into price_uom from public.product_pricing_rules pr
     where pr.product_id = r.product_id and pr.price_channel = 'b2b' and pr.approval_status = 'approved'
     order by pr.created_at desc nulls last limit 1;
    if price_uom is null or lower(btrim(price_uom)) <> lower(btrim(r.commercial_uom)) then
      v := v || jsonb_build_object('code', 'CARTON_UNIT_MISMATCH', 'product_id', r.product_id); continue;
    end if;
    slots := case r.conversion_basis when 'slot_unit' then r.qty * r.slots_per_unit else r.qty / r.ordered_units_per_slot end;
    if slots <> trunc(slots) or slots <= 0 then
      v := v || jsonb_build_object('code', 'PRIMARY_CONTAINER_PARTIAL', 'product_id', r.product_id, 'quantity', r.qty, 'slots', slots); continue;
    end if;
    select c.config_id, c.capacity_slots, c.eligible_packing_groups into cfg
      from unnest(r.carton_config_ids) with ordinality u(cid, ord)
      join public.carton_configurations c on c.config_id = u.cid and c.approval_status = 'approved'
       and (c.effective_from is null or c.effective_from <= now()) and (c.effective_until is null or now() < c.effective_until)
     where c.config_version = (select max(c2.config_version) from public.carton_configurations c2
             where c2.config_id = c.config_id and c2.approval_status = 'approved'
               and (c2.effective_from is null or c2.effective_from <= now()) and (c2.effective_until is null or now() < c2.effective_until))
     order by u.ord limit 1;
    if cfg.config_id is null then
      v := v || jsonb_build_object('code', 'CARTON_CONFIG_NOT_LIVE', 'product_id', r.product_id); continue;
    end if;
    if not (r.packing_group = any (cfg.eligible_packing_groups)) then
      v := v || jsonb_build_object('code', 'CARTON_GROUP_NOT_ELIGIBLE', 'product_id', r.product_id, 'config_id', cfg.config_id); continue;
    end if;
    if not r.full_carton_required then continue; end if;
    gkey := cfg.config_id || '|' || r.packing_group || case when r.requires_separate_carton or not r.mix_allowed then '|' || r.product_id::text else '' end;
    groups := jsonb_set(groups, array[gkey], jsonb_build_object('slots', coalesce((groups -> gkey ->> 'slots')::numeric, 0) + slots, 'cap', cfg.capacity_slots));
  end loop;
  for gentry in select key, (value ->> 'slots')::numeric as s, (value ->> 'cap')::int as cap from jsonb_each(groups) loop
    if gentry.s % gentry.cap <> 0 then
      v := v || jsonb_build_object('code', 'CARTON_INCOMPLETE', 'group', gentry.key, 'slots', gentry.s, 'capacity', gentry.cap,
                                   'missing_slots', gentry.cap - (gentry.s % gentry.cap));
    end if;
  end loop;
  return v;
end $$;

create or replace function public.enforce_order_carton_completeness_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_order uuid; v_enabled boolean; v_viol jsonb;
begin
  v_order := case when tg_op = 'DELETE' then old.order_id else new.order_id end;
  if v_order is null then return null; end if;
  select s.enabled into v_enabled from public.carton_enforcement_settings s where s.singleton;
  if v_enabled is false then return null; end if;                 -- a missing settings row (null) enforces: fail closed
  if not exists (select 1 from public.orders o where o.id = v_order) then return null; end if;
  if exists (select 1 from public.carton_enforcement_exceptions e
              where (e.scope = 'order' and e.ref_id = v_order)
                 or (e.scope = 'sales_order_draft' and e.ref_id in (select d.id from public.sales_order_drafts d where d.promoted_order_id = v_order)))
  then return null; end if;
  -- Serialise concurrent commits touching the same order so each evaluates the other's committed lines (no write skew).
  perform pg_advisory_xact_lock(hashtextextended('carton-enforcement:' || v_order::text, 0));
  v_viol := public.evaluate_order_carton_completeness_v1(v_order);
  if jsonb_array_length(v_viol) > 0 then
    raise exception 'CARTON_ENFORCEMENT_VIOLATION' using errcode = '23514', detail = v_viol::text;
  end if;
  return null;
end $$;

create constraint trigger trg_order_items_carton_enforcement
  after insert or delete or update of product_id, quantity, pack_size, carton_type on public.order_items
  deferrable initially deferred for each row execute function public.enforce_order_carton_completeness_v1();

-- Dispatch gate: an order created after enforcement was switched on cannot advance to packed_ready / cleared_for_dispatch / dispatched
-- while its lines leave a shipping carton incomplete (covers lines edited under an exception-less path, status writers and legacy RPCs).
-- Orders created before enforced_from are legacy and are not stranded mid-flight.
create or replace function public.enforce_order_carton_dispatch_gate_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_enabled boolean; v_from timestamptz; v_viol jsonb;
begin
  select s.enabled, s.enforced_from into v_enabled, v_from from public.carton_enforcement_settings s where s.singleton;
  if v_enabled is false then return new; end if;
  if v_from is not null and new.created_at < v_from then return new; end if;
  if exists (select 1 from public.carton_enforcement_exceptions e
              where (e.scope = 'order' and e.ref_id = new.id)
                 or (e.scope = 'sales_order_draft' and e.ref_id in (select d.id from public.sales_order_drafts d where d.promoted_order_id = new.id)))
  then return new; end if;
  v_viol := public.evaluate_order_carton_completeness_v1(new.id);
  if jsonb_array_length(v_viol) > 0 then
    raise exception 'CARTON_DISPATCH_GATE' using errcode = '23514', detail = v_viol::text;
  end if;
  return new;
end $$;
create trigger trg_orders_carton_dispatch_gate before update of status on public.orders
  for each row when (new.status is distinct from old.status and lower(coalesce(new.status, '')) in ('packed_ready', 'cleared_for_dispatch', 'dispatched'))
  execute function public.enforce_order_carton_dispatch_gate_v1();

create or replace function public.grant_carton_enforcement_exception_v1(p_scope text, p_ref_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid;
begin
  if auth.uid() is null or not coalesce(public.is_internal_staff(auth.uid()), false)
     or upper(coalesce(public.get_user_role(auth.uid()), '')) not in ('ADMIN', 'SUPER_ADMIN', 'OPERATIONS_MANAGER') then
    raise exception 'CARTON_EXCEPTION_NOT_AUTHORISED' using errcode = '42501';
  end if;
  if p_scope = 'order' and not exists (select 1 from public.orders where id = p_ref_id) then raise exception 'CARTON_EXCEPTION_TARGET_NOT_FOUND' using errcode = 'P0002'; end if;
  if p_scope = 'sales_order_draft' and not exists (select 1 from public.sales_order_drafts where id = p_ref_id) then raise exception 'CARTON_EXCEPTION_TARGET_NOT_FOUND' using errcode = 'P0002'; end if;
  if p_scope not in ('order', 'sales_order_draft') then raise exception 'CARTON_EXCEPTION_SCOPE_INVALID' using errcode = '22023'; end if;
  insert into public.carton_enforcement_exceptions (scope, ref_id, reason, granted_by) values (p_scope, p_ref_id, p_reason, auth.uid())
    on conflict (scope, ref_id) do nothing returning id into v_id;
  if v_id is null then select id into v_id from public.carton_enforcement_exceptions where scope = p_scope and ref_id = p_ref_id; end if;
  return v_id;
end $$;

revoke all on function public.evaluate_order_carton_completeness_v1(uuid), public.enforce_order_carton_completeness_v1(), public.enforce_order_carton_dispatch_gate_v1(),
  public.protect_carton_enforcement_audit_v1() from public, anon, authenticated, service_role;
revoke all on function public.grant_carton_enforcement_exception_v1(text, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.grant_carton_enforcement_exception_v1(text, uuid, text) to authenticated;
