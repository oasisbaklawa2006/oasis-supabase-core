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

-- Commercial order-line revision: trusted, monotonic marker for once-per-order
-- enforcement. On the default-OFF path this column remains inert.
alter table public.orders add column carton_line_revision bigint not null default 0;
create table public.carton_enforcement_verifications (
  order_id uuid primary key references public.orders(id) on delete restrict,
  line_revision bigint not null check (line_revision >= 0),
  profile_evidence jsonb not null default '[]'::jsonb,
  verified_at timestamptz not null default clock_timestamp()
);
alter table public.carton_enforcement_settings enable row level security;
alter table public.carton_enforcement_settings force row level security;
alter table public.carton_enforcement_exceptions enable row level security;
alter table public.carton_enforcement_exceptions force row level security;
revoke all on public.carton_enforcement_settings, public.carton_enforcement_exceptions from public, anon, authenticated, service_role;
grant select, update on public.carton_enforcement_settings to service_role;
grant select, insert on public.carton_enforcement_exceptions to service_role;

alter table public.carton_enforcement_verifications enable row level security;
alter table public.carton_enforcement_verifications force row level security;
revoke all on public.carton_enforcement_verifications from public, anon, authenticated, service_role;
create or replace function public.protect_carton_enforcement_audit_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if tg_table_name = 'carton_enforcement_exceptions' then
    raise exception 'carton enforcement exceptions are immutable audit records' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then raise exception 'the enforcement settings row cannot be deleted' using errcode = '23514'; end if;
  new.singleton := true; new.updated_at := now();
  if new.enabled and not old.enabled then
    -- Establish a quiet write barrier before deriving the enforcement cutover.
    -- NOWAIT prevents a settings-vs-order lock cycle; caller retries activation.
    lock table public.order_items, public.orders in share row exclusive mode nowait;
    new.enforced_from := clock_timestamp();
  end if;
  return new;
end $$;
create trigger trg_carton_exceptions_immutable before update or delete on public.carton_enforcement_exceptions
  for each row execute function public.protect_carton_enforcement_audit_v1();
create trigger trg_carton_settings_guard before update or delete on public.carton_enforcement_settings
  for each row execute function public.protect_carton_enforcement_audit_v1();

-- Never trust a client-supplied "already checked" flag. The revision is
-- bumped only by this SECURITY DEFINER order-line trigger. The invoker guard
-- rejects direct edits by API roles, even if those roles can update other order fields.
create or replace function public.guard_carton_line_revision_v1() returns trigger
language plpgsql security invoker set search_path = pg_catalog, public as $$
declare v_owner text;
begin
  select pg_get_userbyid(p.proowner) into v_owner
    from pg_proc p where p.oid = 'public.touch_carton_line_revision_v1()'::regprocedure;
  if new.carton_line_revision is distinct from old.carton_line_revision
     and current_user is distinct from v_owner then
    raise exception 'CARTON_LINE_REVISION_INTERNAL_ONLY' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger trg_orders_carton_revision_guard
  before update of carton_line_revision on public.orders
  for each row execute function public.guard_carton_line_revision_v1();

-- Fail fast if the global carton mutex is busy, including RPCs which may already
-- hold row locks from SELECT FOR UPDATE. Never wait on the mutex after a row lock:
-- a retryable 55P03 is safer than a deadlock with an existing operational RPC.
-- Acquire the global mutation mutex BEFORE touching any order or line rows.
-- Statement-level triggers fire before row locks, unlike the AFTER ROW revision
-- trigger. This preserves a consistent lock order for enabled-mode operations.
-- The default-OFF path without existing accepted snapshots skips the mutex. Throughput at activation
-- requires separate two-session/load testing before commissioning.
create or replace function public.acquire_carton_global_mutation_lock_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_enabled boolean;
begin
  select s.enabled into v_enabled from public.carton_enforcement_settings s where s.singleton;
  -- Once an order has been verified, even OFF-mode commercial edits must
  -- acquire the mutex before row locks so the accepted revision can be invalidated.
  if v_enabled is not false or exists (select 1 from public.carton_enforcement_verifications) then
    if not pg_try_advisory_xact_lock(hashtextextended('carton-enforcement-global-v1', 0)) then
      raise exception 'CARTON_CONCURRENCY_RETRY' using errcode = '55P03',
        hint = 'Retry the complete order transaction; global carton mutex is busy';
    end if;
  end if;
  return null;
end $$;
create trigger trg_carton_line_global_stmt_lock
  before insert or update or delete on public.order_items
  for each statement execute function public.acquire_carton_global_mutation_lock_v1();
create trigger trg_carton_order_global_stmt_lock
  before insert or update or delete on public.orders
  for each statement execute function public.acquire_carton_global_mutation_lock_v1();
-- The profile and physical carton masters must not change between an accepted
-- completeness evaluation and its immutable evidence snapshot. The same mutex
-- serializes writers; enabled-mode contention returns 55P03 for safe retry.
create trigger trg_carton_profile_global_stmt_lock
  before insert or update or delete on public.product_packing_profiles
  for each statement execute function public.acquire_carton_global_mutation_lock_v1();
create trigger trg_carton_config_global_stmt_lock
  before insert or update or delete on public.carton_configurations
  for each statement execute function public.acquire_carton_global_mutation_lock_v1();
revoke all on function public.acquire_carton_global_mutation_lock_v1()
  from public, anon, authenticated, service_role;

-- A single advisory lock identifier prevents the inverse-order cycle caused
-- by taking per-order locks during separate deferred events. It is taken at
-- the first actual line mutation, BEFORE the transaction can bump revisions.
-- This serializes enabled-mode commercial changes; throughput must be load
-- tested independently before activating the policy.
create or replace function public.touch_carton_line_revision_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_enabled boolean; v_old uuid; v_new uuid; v_order uuid;
begin
  select s.enabled into v_enabled from public.carton_enforcement_settings s where s.singleton;
  -- An UPDATE OF a commercial column can be a no-op; do not invalidate
  -- historically accepted packing evidence unless a commercial value changes.
  if tg_op = 'UPDATE'
     and new.order_id is not distinct from old.order_id
     and new.product_id is not distinct from old.product_id
     and new.quantity is not distinct from old.quantity
     and new.pack_size is not distinct from old.pack_size
     and new.carton_type is not distinct from old.carton_type
  then return null; end if;
  if tg_op <> 'INSERT' then v_old := old.order_id; end if;
  if tg_op <> 'DELETE' then v_new := new.order_id; end if;
  -- Never reuse a trusted ON-mode snapshot after the order was commercially
  -- changed during a later OFF interval: its revision must still advance.
  if v_enabled is false and not exists (
      select 1 from public.carton_enforcement_verifications z
      where z.order_id in (v_old, v_new)
  ) then return null; end if;
  if not pg_try_advisory_xact_lock(hashtextextended('carton-enforcement-global-v1', 0)) then
      raise exception 'CARTON_CONCURRENCY_RETRY' using errcode = '55P03',
        hint = 'Retry the complete order transaction; global carton mutex is busy';
    end if;
  for v_order in
    select distinct x.id from (values (v_old), (v_new)) as x(id)
     where x.id is not null order by x.id
  loop
    update public.orders o set carton_line_revision = o.carton_line_revision + 1 where o.id = v_order;
  end loop;
  return null;
end $$;
create trigger trg_a_order_items_carton_revision
  after insert or delete or update of order_id, product_id, quantity, pack_size, carton_type on public.order_items
  for each row execute function public.touch_carton_line_revision_v1();

-- Accepted order state is frozen by a trusted monotonically increased
-- revision, not by the newest (potentially retired) packing-profile version.
-- The audit snapshot also records the profile versions used on acceptance.
-- This helper is private to database triggers.
create or replace function public.assert_carton_order_ready_v1(
  p_order_id uuid, p_failure text default 'CARTON_ENFORCEMENT_VIOLATION'
) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_enabled boolean;
  v_from timestamptz;
  v_created timestamptz;
  v_revision bigint;
  v_viol jsonb;
  v_profiles jsonb;
begin
  select enabled, enforced_from into v_enabled, v_from
    from public.carton_enforcement_settings where singleton;
  if v_enabled is false then return; end if;
  if not pg_try_advisory_xact_lock(hashtextextended('carton-enforcement-global-v1', 0)) then
      raise exception 'CARTON_CONCURRENCY_RETRY' using errcode = '55P03',
        hint = 'Retry the complete order transaction; global carton mutex is busy';
    end if;
  select o.created_at, o.carton_line_revision into v_created, v_revision
    from public.orders o where o.id = p_order_id;
  if not found then return; end if;
  -- Only orders never accepted under an earlier enforcement epoch are legacy.
  -- A verified order edited while OFF must not regain legacy exemption when
  -- enabled is switched ON again (enforced_from advances on each activation).
  if v_from is not null and v_created < v_from
     and not exists (select 1 from public.carton_enforcement_verifications z
                      where z.order_id = p_order_id)
  then return; end if;
  if exists (
    select 1 from public.carton_enforcement_exceptions e
     where (e.scope = 'order' and e.ref_id = p_order_id)
        or (e.scope = 'sales_order_draft' and e.ref_id in (
          select d.id from public.sales_order_drafts d where d.promoted_order_id = p_order_id))
  ) then return; end if;
  if exists (select 1 from public.carton_enforcement_verifications z
             where z.order_id = p_order_id and z.line_revision = v_revision)
  then return; end if;

  v_viol := public.evaluate_order_carton_completeness_v1(p_order_id);
  if jsonb_array_length(v_viol) > 0 then
    raise exception '%', p_failure using errcode = '23514', detail = v_viol::text;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'order_item_id', oi.id, 'product_id', oi.product_id,
    'profile_id', p.id, 'profile_version', p.profile_version
  ) order by oi.id), '[]'::jsonb) into v_profiles
  from public.order_items oi
  left join lateral (
    select pp.id, pp.profile_version from public.product_packing_profiles pp
    where pp.product_id = oi.product_id and pp.variant_id is null and pp.approval_status = 'approved'
      and (pp.effective_from is null or pp.effective_from <= now())
      and (pp.effective_until is null or now() < pp.effective_until)
    order by pp.profile_version desc limit 1
  ) p on true
  where oi.order_id = p_order_id;
  insert into public.carton_enforcement_verifications
      (order_id, line_revision, profile_evidence, verified_at)
  values (p_order_id, v_revision, v_profiles, clock_timestamp())
  on conflict (order_id) do update
     set line_revision = excluded.line_revision,
         profile_evidence = excluded.profile_evidence,
         verified_at = excluded.verified_at;
end $$;


-- Returns a jsonb array of violations for saved order lines ([] = complete).
-- Use the per-line commercial unit captured at order creation/amendment (order_items.pack_size),
-- NOT a live product price or catalogue publication. An expired/replaced sales offer
-- cannot retroactively invalidate a submitted order. Unknown/mixed line units fail closed.
create or replace function public.evaluate_order_carton_candidate_v1(p_order_id uuid, p_prefer_individual boolean) returns jsonb
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
  -- A verified, unmodified order is governed by its immutable accepted
  -- packing decision, not by subsequent catalogue or profile retirement.
  if exists (
    select 1 from public.carton_enforcement_verifications z
    join public.orders o on o.id = z.order_id
    where o.id = p_order_id and z.line_revision = o.carton_line_revision
  ) then return '[]'::jsonb; end if;
  if not exists (select 1 from public.order_items oi where oi.order_id = p_order_id) then
    return jsonb_build_array(jsonb_build_object('code', 'CARTON_ORDER_EMPTY'));
  end if;
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
     order by case when p_prefer_individual and mod(slots, c.capacity_slots) = 0 then 0 else 1 end, u.ord limit 1;
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
      gkey := jsonb_build_array('product', cfg.config_id, r.product_id::text)::text;
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
        then jsonb_build_array('group', cfg.config_id, r.packing_group)::text
        else jsonb_build_array('mix_set', cfg.config_id, v_mix_ordinal)::text
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

-- Keep the original preferred-configuration grouping when it makes a full
-- valid mixed packing allocation; only attempt an individually divisible
-- alternative strategy if the complete preferred grouping fails.
-- Two deterministic passes, never an unbounded combinatorial search.
create or replace function public.evaluate_order_carton_completeness_v1(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v jsonb;
begin
  v := public.evaluate_order_carton_candidate_v1(p_order_id, false);
  if jsonb_array_length(v) = 0 then return v; end if;
  return public.evaluate_order_carton_candidate_v1(p_order_id, true);
end $$;

-- All events in a transaction consult the same authoritative revision. Only
-- the first event per affected order evaluates profiles and cartons; later
-- events find the verified revision and return in constant time.
create or replace function public.enforce_order_carton_completeness_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_old uuid; v_new uuid; v_order uuid;
begin
  if tg_op <> 'INSERT' then v_old := old.order_id; end if;
  if tg_op <> 'DELETE' then v_new := new.order_id; end if;
  for v_order in
    select distinct x.id from (values (v_old), (v_new)) as x(id)
     where x.id is not null order by x.id
  loop
    perform public.assert_carton_order_ready_v1(v_order);
  end loop;
  return null;
end $$;

create or replace function public.enforce_new_order_carton_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform public.assert_carton_order_ready_v1(new.id);
  return null;
end $$;

create constraint trigger trg_order_items_carton_enforcement
  after insert or delete or update of order_id, product_id, quantity, pack_size, carton_type on public.order_items
  deferrable initially deferred for each row execute function public.enforce_order_carton_completeness_v1();

-- A newly submitted order without lines must not bypass the per-line trigger.
-- Checked at commit so legitimate multi-statement checkout still succeeds.
create constraint trigger trg_orders_carton_new_order_enforcement
  after insert on public.orders
  deferrable initially deferred for each row execute function public.enforce_new_order_carton_v1();

-- Dispatch gate: an order created after enforcement was switched on cannot advance to packed_ready / cleared_for_dispatch / dispatched
-- while its lines leave a shipping carton incomplete (covers lines edited under an exception-less path, status writers and legacy RPCs).
-- Orders created before enforced_from are legacy and are not stranded mid-flight.
create or replace function public.enforce_order_carton_dispatch_gate_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform public.assert_carton_order_ready_v1(new.id, 'CARTON_DISPATCH_GATE');
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
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_enabled boolean;
begin
  select s.enabled into v_enabled from public.carton_enforcement_settings s where s.singleton;
  -- A previously enforced and verified order cannot be backdated even
  -- after an administrator temporarily disables future enforcement.
  if v_enabled is false then
    if tg_op = 'INSERT' then return new; end if;
    if not exists (select 1 from public.carton_enforcement_verifications
                    where order_id = old.id) then return new; end if;
  end if;
  if tg_op = 'INSERT' then
    new.created_at := clock_timestamp();
  elsif new.created_at is distinct from old.created_at then
    raise exception 'CARTON_ORDER_CREATED_AT_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end $$;
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

-- Preserve the immutable confirmed checkout UOM on new CUSTOMER_APP order
-- lines. The canonical submit writer can otherwise copy an older draft UOM
-- despite having quoted and frozen the newly approved commercial UOM.
-- This compatibility guard is inert while enforcement is default OFF.
create or replace function public.align_carton_quoted_order_item_uom_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $carton_uom_guard$
declare v_enabled boolean; v_origin text; v_snapshot jsonb;
        v_count integer; v_uom text; v_quantity numeric;
begin
  select enabled into v_enabled from public.carton_enforcement_settings where singleton;
  if v_enabled is false then return new; end if;
  select o.order_origin, o.checkout_snapshot into v_origin, v_snapshot
    from public.orders o where o.id = new.order_id;
  if v_origin is distinct from 'CUSTOMER_APP'
     or jsonb_typeof(v_snapshot) is distinct from 'array'
     or jsonb_array_length(v_snapshot) = 0 then return new; end if;
  select count(*)::integer, min(nullif(btrim(x.line->>'uom'),'')),
         min((x.line->>'quantity')::numeric)
    into v_count, v_uom, v_quantity
    from jsonb_array_elements(v_snapshot) as x(line)
   where x.line->>'product_id' = new.product_id::text;
  if v_count <> 1 or v_uom is null or v_quantity is distinct from new.quantity then
    raise exception 'CARTON_CHECKOUT_SNAPSHOT_MISMATCH'
      using errcode = '23514', detail = 'Saved line must match exactly one confirmed quote line';
  end if;
  new.pack_size := v_uom;
  return new;
end $carton_uom_guard$;
create trigger trg_carton_quoted_order_item_uom
  before insert on public.order_items for each row
  execute function public.align_carton_quoted_order_item_uom_v1();
revoke all on function public.align_carton_quoted_order_item_uom_v1()
  from public, anon, authenticated, service_role;

revoke all on function public.evaluate_order_carton_completeness_v1(uuid), public.enforce_order_carton_completeness_v1(), public.enforce_order_carton_dispatch_gate_v1(),
  public.protect_carton_enforcement_audit_v1() from public, anon, authenticated, service_role;
revoke all on function public.evaluate_order_carton_candidate_v1(uuid, boolean)
  from public, anon, authenticated, service_role;
revoke all on function public.grant_carton_enforcement_exception_v1(text, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.grant_carton_enforcement_exception_v1(text, uuid, text) to authenticated;
revoke all on function public.guard_carton_line_revision_v1(), public.touch_carton_line_revision_v1(),
  public.assert_carton_order_ready_v1(uuid, text), public.enforce_new_order_carton_v1()
  from public, anon, authenticated, service_role;
