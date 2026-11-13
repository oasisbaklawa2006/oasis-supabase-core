-- Core carton enforcement v1: mandatory full shipping cartons at the order-line chokepoint.
-- Depends on 20261113130000 (carton_configurations / product_packing_profiles). Default OFF (fail-closed once enabled).
-- One chokepoint: a DEFERRABLE INITIALLY DEFERRED constraint trigger on public.order_items evaluates the final state of the
-- order (and both orders for a reassignment) at COMMIT, so it covers submit_customer_order_v1, amendments and WhatsApp promotion
-- (promote_sales_order_draft_to_order_governed_v1) and any other writer, without rewriting those functions.
-- Governed, immutable exceptions allow staff / WhatsApp orders that Operations explicitly approves.

-- Hard precondition: this migration reads the governance tables created by 20261113130000 (#471). Enforcement ships OFF, but if it were ever
-- switched on without those tables every order write would fail. Refuse to apply out of order instead of relying on file-name ordering alone.
do $$
begin
  if to_regclass('public.carton_configurations') is null or to_regclass('public.product_packing_profiles') is null then
    raise exception 'MIGRATION_ORDER_VIOLATION: 20261113130000_buyer_carton_packing_profile_projection_v1 must be applied before 20261113130100 (carton_configurations / product_packing_profiles missing)';
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
  reason text not null check (char_length(regexp_replace(reason, '[[:space:]]', '', 'g')) >= 15),
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

-- Returns a jsonb array of violations for saved order lines ([] = complete).
-- Use the per-line commercial unit captured at order creation/amendment (order_items.pack_size),
-- NOT a live product price or catalogue publication. An expired/replaced sales offer
-- cannot retroactively invalidate a submitted order. Unknown/mixed line units fail closed.
create or replace function public.evaluate_order_carton_completeness_v1(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v jsonb := '[]'::jsonb;
  groups jsonb := '{}'::jsonb;
  r record;
  cfg record;
  slots numeric;
  gkey text;
  gentry record;
  v_mix_ordinal bigint;
  v_mix_memberships bigint;
begin
  for r in
    with ln as (
      select oi.product_id, sum(oi.quantity) as qty,
             min(nullif(lower(btrim(oi.pack_size)), '')) as saved_uom,
             count(distinct nullif(lower(btrim(oi.pack_size)), '')) as distinct_saved_uoms,
             count(*) filter (where nullif(btrim(oi.pack_size), '') is null) as missing_saved_uoms
        from public.order_items oi
       where oi.order_id = p_order_id
       group by oi.product_id
    )
    select ln.product_id, ln.qty, ln.saved_uom, ln.distinct_saved_uoms, ln.missing_saved_uoms,
           pf.id as profile_id, pf.packing_group, pf.conversion_basis, pf.slots_per_unit, pf.ordered_units_per_slot,
           pf.commercial_uom, pf.carton_config_ids, pf.requires_separate_carton, pf.mix_allowed, pf.full_carton_required
      from ln
      left join lateral (
        select p.* from public.product_packing_profiles p
         where p.product_id = ln.product_id and p.variant_id is null and p.approval_status = 'approved'
           and (p.effective_from is null or p.effective_from <= now()) and (p.effective_until is null or now() < p.effective_until)
         order by p.profile_version desc limit 1
      ) pf on true
  loop
    if r.profile_id is null then
      v := v || jsonb_build_object('code', 'CARTON_PROFILE_MISSING', 'product_id', r.product_id); continue;
    end if;
    if r.missing_saved_uoms > 0 or r.distinct_saved_uoms <> 1
       or r.saved_uom is distinct from lower(btrim(r.commercial_uom)) then
      v := v || jsonb_build_object('code', 'CARTON_UNIT_MISMATCH', 'product_id', r.product_id); continue;
    end if;
    slots := case r.conversion_basis when 'slot_unit' then r.qty * r.slots_per_unit else r.qty / r.ordered_units_per_slot end;
    if slots <> trunc(slots) or slots <= 0 then
      v := v || jsonb_build_object('code', 'PRIMARY_CONTAINER_PARTIAL', 'product_id', r.product_id, 'quantity', r.qty, 'slots', slots); continue;
    end if;
    -- Prefer an eligible, individually complete approved carton from all permitted
    -- configurations, not merely the first array member. Otherwise retain original
    -- preference order for multi-product packing/mixable-group aggregation.
    select c.config_id, c.capacity_slots, c.eligible_packing_groups, c.mixable_group_sets into cfg
      from unnest(r.carton_config_ids) with ordinality u(cid, ord)
      join public.carton_configurations c on c.config_id = u.cid and c.approval_status = 'approved'
       and (c.effective_from is null or c.effective_from <= now()) and (c.effective_until is null or now() < c.effective_until)
     where c.config_version = (select max(c2.config_version) from public.carton_configurations c2
             where c2.config_id = c.config_id and c2.approval_status = 'approved'
               and (c2.effective_from is null or c2.effective_from <= now()) and (c2.effective_until is null or now() < c2.effective_until))
       and (r.packing_group = any (c.eligible_packing_groups)) is true
     order by case when mod(slots, c.capacity_slots) = 0 then 0 else 1 end, u.ord limit 1;
    if cfg.config_id is null then
      if exists (
        select 1 from unnest(r.carton_config_ids) u(cid)
        join public.carton_configurations c on c.config_id = u.cid and c.approval_status = 'approved'
          and (c.effective_from is null or c.effective_from <= now()) and (c.effective_until is null or now() < c.effective_until)
        where c.config_version = (select max(c2.config_version) from public.carton_configurations c2
                where c2.config_id = c.config_id and c2.approval_status = 'approved'
                  and (c2.effective_from is null or c2.effective_from <= now()) and (c2.effective_until is null or now() < c2.effective_until))
      ) then
        v := v || jsonb_build_object('code', 'CARTON_GROUP_NOT_ELIGIBLE', 'product_id', r.product_id); continue;
      end if;
      v := v || jsonb_build_object('code', 'CARTON_CONFIG_NOT_LIVE', 'product_id', r.product_id); continue;
    end if;
    if not r.full_carton_required then continue; end if;
    if r.requires_separate_carton or not r.mix_allowed then
      gkey := cfg.config_id || '|product|' || r.product_id::text;
    else
      -- An approved mixable_group_set permits different packing groups in ONE carton.
      -- Overlapping sets are ambiguous: fail closed instead of silently treating them
      -- as an unapproved transitive mixing permission.
      select count(*), min(m.ord) into v_mix_memberships, v_mix_ordinal
        from jsonb_array_elements(cfg.mixable_group_sets) with ordinality as m(group_set, ord)
       where m.group_set ? r.packing_group;
      if v_mix_memberships > 1 then
        v := v || jsonb_build_object('code', 'CARTON_MIXING_AMBIGUOUS', 'product_id', r.product_id, 'config_id', cfg.config_id);
        continue;
      end if;
      gkey := case when v_mix_ordinal is null
        then cfg.config_id || '|group|' || r.packing_group
        else cfg.config_id || '|mix_set|' || v_mix_ordinal::text
      end;
    end if;
    groups := jsonb_set(groups, array[gkey],
      jsonb_build_object('slots', coalesce((groups -> gkey ->> 'slots')::numeric, 0) + slots, 'cap', cfg.capacity_slots));
  end loop;
  for gentry in select key, (value ->> 'slots')::numeric as s, (value ->> 'cap')::int as cap from jsonb_each(groups) loop
    if gentry.s % gentry.cap <> 0 then
      v := v || jsonb_build_object('code', 'CARTON_INCOMPLETE', 'group', gentry.key, 'slots', gentry.s,
                                   'capacity', gentry.cap, 'missing_slots', gentry.cap - (gentry.s % gentry.cap));
    end if;
  end loop;
  return v;
end $$;

create or replace function public.enforce_order_carton_completeness_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_order uuid;
  v_old_order uuid;
  v_new_order uuid;
  v_enabled boolean;
  v_from timestamptz;
  v_created timestamptz;
  v_viol jsonb;
begin
  if tg_op <> 'INSERT' then v_old_order := old.order_id; end if;
  if tg_op <> 'DELETE' then v_new_order := new.order_id; end if;
  select s.enabled, s.enforced_from into v_enabled, v_from
    from public.carton_enforcement_settings s where s.singleton;
  if v_enabled is false then return null; end if;  -- missing settings row still fails closed
  -- A reassignment affects BOTH old and new orders. Acquire the two advisory locks
  -- in sorted order before evaluating either order, avoiding an opposite-order cycle.
  for v_order in
    select distinct x.id from (values (v_old_order), (v_new_order)) as x(id)
     where x.id is not null order by x.id
  loop
    perform pg_advisory_xact_lock(hashtextextended('carton-enforcement:' || v_order::text, 0));
  end loop;
  for v_order in
    select distinct x.id from (values (v_old_order), (v_new_order)) as x(id)
     where x.id is not null order by x.id
  loop
    select o.created_at into v_created from public.orders o where o.id = v_order;
    if not found then continue; end if;
    if v_from is not null and v_created < v_from then continue; end if;
    if exists (select 1 from public.carton_enforcement_exceptions e
               where (e.scope = 'order' and e.ref_id = v_order)
                  or (e.scope = 'sales_order_draft' and e.ref_id in (
                      select d.id from public.sales_order_drafts d where d.promoted_order_id = v_order)))
    then continue; end if;
    v_viol := public.evaluate_order_carton_completeness_v1(v_order);
    if jsonb_array_length(v_viol) > 0 then
      raise exception 'CARTON_ENFORCEMENT_VIOLATION' using errcode = '23514', detail = v_viol::text;
    end if;
  end loop;
  return null;
end $$;

create constraint trigger trg_order_items_carton_enforcement
  after insert or delete or update of order_id, product_id, quantity, pack_size, carton_type on public.order_items
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

-- Do not derive legacy eligibility from staff-writable created_at after enforcement.
-- An order inserted while enforcement is ON receives the actual server timestamp;
-- subsequent backdating is rejected before the dispatch and deferred line gates.
-- The old default-OFF behavior is preserved while the flag is explicitly false.
create or replace function public.guard_carton_order_created_at_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $
declare v_enabled boolean;
begin
  select s.enabled into v_enabled from public.carton_enforcement_settings s where s.singleton;
  if v_enabled is false then return new; end if;
  if tg_op = 'INSERT' then
    new.created_at := clock_timestamp();
  elsif new.created_at is distinct from old.created_at then
    raise exception 'CARTON_ORDER_CREATED_AT_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end $;
create trigger trg_orders_carton_created_at_guard
  before insert or update of created_at on public.orders
  for each row execute function public.guard_carton_order_created_at_v1();
revoke all on function public.guard_carton_order_created_at_v1() from public, anon, authenticated, service_role;


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
