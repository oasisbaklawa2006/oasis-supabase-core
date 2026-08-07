-- Tranche D: governed customer checkout, advance calculation, and legacy financial
-- trigger isolation for CUSTOMER_APP orders.

-- ══════════════════════════════════════════════════════════════════════
-- order_origin discriminator + checkout metadata on orders
-- ══════════════════════════════════════════════════════════════════════

alter table public.orders
  add column if not exists order_origin text not null default 'LEGACY_ERP'
    check (order_origin in ('LEGACY_ERP', 'CUSTOMER_APP'));

alter table public.orders
  add column if not exists checkout_idempotency_key text;

alter table public.orders
  add column if not exists checkout_snapshot jsonb;

comment on column public.orders.order_origin is
  'Financial/advance semantics discriminator: LEGACY_ERP (50% advance trigger) vs CUSTOMER_APP (30% round-up advance).';

comment on column public.orders.checkout_idempotency_key is
  'Client-generated idempotency key for CUSTOMER_APP checkout; scoped per company.';

comment on column public.orders.checkout_snapshot is
  'Immutable authoritative checkout snapshot for CUSTOMER_APP orders (lines, pricing, MOQ at submit time).';

create unique index if not exists uq_orders_customer_app_checkout_idempotency
  on public.orders (company_id, checkout_idempotency_key)
  where order_origin = 'CUSTOMER_APP'
    and checkout_idempotency_key is not null;

-- ══════════════════════════════════════════════════════════════════════
-- Authoritative customer advance: 30% rounded UP to next ₹500
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.calculate_customer_advance_v1(p_sales_order_value numeric)
returns numeric
language sql
immutable
set search_path to pg_catalog, public
as $$
  select case
    when p_sales_order_value is null or p_sales_order_value <= 0 then 0::numeric
    else ceil((p_sales_order_value * 0.30) / 500) * 500
  end;
$$;

comment on function public.calculate_customer_advance_v1(numeric) is
  'Customer-app advance: 30% of authoritative SO value, rounded up to the next ₹500 increment (NUMERIC arithmetic).';

revoke all on function public.calculate_customer_advance_v1(numeric) from public, anon;
grant execute on function public.calculate_customer_advance_v1(numeric) to authenticated, service_role;

-- ══════════════════════════════════════════════════════════════════════
-- CUSTOMER_APP financial recalculation (buyer pricing authority)
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.recalculate_customer_app_order_financials(p_order_id uuid)
returns numeric
language plpgsql
security definer
set search_path to pg_catalog, public
as $$
declare
  v_company_id uuid;
  v_subtotal numeric := 0;
  v_total numeric := 0;
  v_line record;
  v_auth record;
  v_line_base numeric;
  v_line_total numeric;
begin
  select o.company_id into v_company_id
  from public.orders o
  where o.id = p_order_id
    and o.order_origin = 'CUSTOMER_APP';

  if v_company_id is null then
    return 0;
  end if;

  for v_line in
    select oi.product_id, oi.quantity
    from public.order_items oi
    where oi.order_id = p_order_id
  loop
    select * into v_auth
    from public.customer_resolve_buyer_product_authority_v1(v_company_id, v_line.product_id);

    if not coalesce(v_auth.is_available, false) then
      continue;
    end if;

    v_line_base := coalesce(v_line.quantity, 0) * coalesce(v_auth.selling_price, 0);
    v_subtotal := v_subtotal + v_line_base;

    if coalesce(v_auth.tax_inclusive, false) then
      v_line_total := v_line_base;
    else
      v_line_total := v_line_base * (1 + coalesce(v_auth.gst_rate, 0) / 100);
    end if;

    v_total := v_total + v_line_total;
  end loop;

  v_total := round(v_total, 2);

  update public.orders
  set sales_order_value = v_total,
      advance_required = public.calculate_customer_advance_v1(v_total)
  where id = p_order_id
    and order_origin = 'CUSTOMER_APP';

  return v_total;
end;
$$;

comment on function public.recalculate_customer_app_order_financials(uuid) is
  'Recomputes CUSTOMER_APP order financials from buyer pricing authority; never applies legacy 50% advance.';

revoke all on function public.recalculate_customer_app_order_financials(uuid) from public, anon, authenticated;
grant execute on function public.recalculate_customer_app_order_financials(uuid) to service_role;

-- ══════════════════════════════════════════════════════════════════════
-- Legacy trigger isolation: preserve 50% for LEGACY_ERP only
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.recalculate_erp_order_financials()
returns trigger
language plpgsql
security definer
set search_path to pg_catalog, public
as $$
declare
  v_origin text;
  calc_subtotal numeric := 0;
  calc_total numeric := 0;
begin
  select coalesce(o.order_origin, 'LEGACY_ERP') into v_origin
  from public.orders o
  where o.id = new.order_id;

  if v_origin = 'CUSTOMER_APP' then
    perform public.recalculate_customer_app_order_financials(new.order_id);
    return new;
  end if;

  select coalesce(
    sum(
      coalesce(oi.quantity, 0) * coalesce(
        p.price_per_kg,
        p.base_price,
        p.price_b2b,
        p.price_wholesale,
        p.wholesale_price,
        0
      )
    ),
    0
  )
  into calc_subtotal
  from public.order_items oi
  join public.products p on p.id = oi.product_id
  where oi.order_id = new.order_id;

  calc_total := calc_subtotal * 1.18;

  update public.orders
  set sales_order_value = calc_total,
      advance_required = calc_total * 0.5
  where id = new.order_id;

  return new;
end;
$$;

create or replace function public.restore_order_financials(_order_id uuid)
returns numeric
language plpgsql
security definer
set search_path to pg_catalog, public
as $$
declare
  v_origin text;
  calc_subtotal numeric := 0;
  calc_total numeric := 0;
begin
  select coalesce(order_origin, 'LEGACY_ERP') into v_origin
  from public.orders
  where id = _order_id;

  if v_origin = 'CUSTOMER_APP' then
    return public.recalculate_customer_app_order_financials(_order_id);
  end if;

  select coalesce(
    sum(
      coalesce(oi.quantity, 0) * coalesce(
        p.price_per_kg,
        p.base_price,
        p.price_b2b,
        p.price_wholesale,
        p.wholesale_price,
        0
      )
    ),
    0
  )
  into calc_subtotal
  from public.order_items oi
  join public.products p on p.id = oi.product_id
  where oi.order_id = _order_id;

  calc_total := calc_subtotal * 1.18;

  update public.orders
  set sales_order_value = calc_total,
      advance_required = calc_total * 0.5
  where id = _order_id;

  return calc_total;
end;
$$;

-- ══════════════════════════════════════════════════════════════════════
-- submit_customer_order_v1 — idempotent checkout / SO promotion
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.submit_customer_order_v1(
  p_idempotency_key text,
  p_requested_dispatch_date date default null
)
returns table (
  order_id uuid,
  order_number text,
  sales_order_value numeric,
  advance_required numeric,
  draft_id uuid,
  is_duplicate_submission boolean
)
language plpgsql
security definer
set search_path to pg_catalog, public, auth
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_company_id uuid;
  v_draft public.customer_order_drafts%rowtype;
  v_existing_order_id uuid;
  v_existing_order_number text;
  v_existing_so_value numeric;
  v_existing_advance numeric;
  v_promoted_draft_id uuid;
  v_order_id uuid;
  v_order_number text;
  v_snapshot jsonb := '[]'::jsonb;
  v_line record;
  v_auth record;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required' using errcode = '28000';
  end if;

  if coalesce(btrim(p_idempotency_key), '') = '' then
    raise exception 'VALIDATION_FAILED: idempotency_key is required';
  end if;

  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('customer_checkout:' || v_company_id::text || ':' || btrim(p_idempotency_key), 0)
  );

  select o.id, o.order_number, o.sales_order_value, o.advance_required
  into v_existing_order_id, v_existing_order_number, v_existing_so_value, v_existing_advance
  from public.orders o
  where o.company_id = v_company_id
    and o.order_origin = 'CUSTOMER_APP'
    and o.checkout_idempotency_key = btrim(p_idempotency_key)
  limit 1;

  if v_existing_order_id is not null then
    select d.id into v_promoted_draft_id
    from public.customer_order_drafts d
    where d.promoted_order_id = v_existing_order_id
    limit 1;

    return query select
      v_existing_order_id,
      v_existing_order_number,
      v_existing_so_value,
      v_existing_advance,
      v_promoted_draft_id,
      true;
    return;
  end if;

  select * into v_draft
  from public.customer_order_drafts d
  where d.company_id = v_company_id
    and d.status = 'active'
  for update;

  if not found then
    raise exception 'DRAFT_NOT_FOUND: no active customer order draft exists for checkout' using errcode = 'P0002';
  end if;

  perform public.customer_order_draft_audit_v1(
    v_draft.id, v_company_id, v_uid, 'SUBMIT_ATTEMPT',
    jsonb_build_object('idempotency_key', btrim(p_idempotency_key)));

  perform public.customer_recompute_draft_readiness_v1(v_draft.id);
  select * into v_draft from public.customer_order_drafts where id = v_draft.id;

  if v_draft.readiness_status <> 'ready' then
    raise exception 'DRAFT_NOT_READY: draft cannot be submitted (issues: %)', v_draft.readiness_issues::text;
  end if;

  for v_line in
    select l.* from public.customer_order_draft_lines l where l.draft_id = v_draft.id
  loop
    select * into v_auth
    from public.customer_resolve_buyer_product_authority_v1(v_company_id, v_line.product_id);

    if not coalesce(v_auth.is_available, false) then
      raise exception 'PRODUCT_UNAVAILABLE: product % is not available at checkout', v_line.product_id;
    end if;

    if not public.customer_validate_order_quantity_v1(
      v_line.quantity,
      v_auth.minimum_order_quantity,
      v_auth.order_increment,
      v_auth.min_carton_qty
    ) then
      raise exception 'QUANTITY_RULE_VIOLATION: product % failed MOQ/increment/carton validation at checkout', v_line.product_id;
    end if;

    v_snapshot := v_snapshot || jsonb_build_array(jsonb_build_object(
      'product_id', v_line.product_id,
      'quantity', v_line.quantity,
      'selling_price', v_auth.selling_price,
      'currency', v_auth.currency,
      'uom', v_auth.uom,
      'gst_rate', v_auth.gst_rate,
      'tax_inclusive', v_auth.tax_inclusive,
      'sku', v_auth.sku,
      'product_name', v_auth.product_name,
      'minimum_order_quantity', v_auth.minimum_order_quantity,
      'order_increment', v_auth.order_increment,
      'min_carton_qty', v_auth.min_carton_qty
    ));
  end loop;

  insert into public.orders (
    company_id,
    status,
    order_origin,
    checkout_idempotency_key,
    checkout_snapshot,
    requested_dispatch_date
  ) values (
    v_company_id,
    'submitted',
    'CUSTOMER_APP',
    btrim(p_idempotency_key),
    v_snapshot,
    p_requested_dispatch_date
  )
  returning id, order_number into v_order_id, v_order_number;

  for v_line in
    select l.* from public.customer_order_draft_lines l where l.draft_id = v_draft.id
  loop
    insert into public.order_items (order_id, product_id, quantity, pack_size)
    values (
      v_order_id,
      v_line.product_id,
      v_line.quantity,
      v_line.uom_snapshot
    );
  end loop;

  perform public.recalculate_customer_app_order_financials(v_order_id);

  update public.customer_order_drafts
  set status = 'promoted',
      promoted_order_id = v_order_id,
      updated_at = now()
  where id = v_draft.id;

  perform public.customer_order_draft_audit_v1(
    v_draft.id, v_company_id, v_uid, 'PROMOTE',
    jsonb_build_object('order_id', v_order_id, 'idempotency_key', btrim(p_idempotency_key)));

  return query
  select
    v_order_id,
    v_order_number,
    o.sales_order_value,
    o.advance_required,
    v_draft.id,
    false
  from public.orders o
  where o.id = v_order_id;
exception
  when unique_violation then
    select o.id, o.order_number, o.sales_order_value, o.advance_required
    into v_existing_order_id, v_existing_order_number, v_existing_so_value, v_existing_advance
    from public.orders o
    where o.company_id = v_company_id
      and o.order_origin = 'CUSTOMER_APP'
      and o.checkout_idempotency_key = btrim(p_idempotency_key)
    limit 1;

    if v_existing_order_id is null then
      raise;
    end if;

    select d.id into v_promoted_draft_id
    from public.customer_order_drafts d
    where d.promoted_order_id = v_existing_order_id
    limit 1;

    return query select
      v_existing_order_id,
      v_existing_order_number,
      v_existing_so_value,
      v_existing_advance,
      v_promoted_draft_id,
      true;
end;
$$;

comment on function public.submit_customer_order_v1(text, date) is
  'Idempotent CUSTOMER_APP checkout: promotes active draft to exactly one Sales Order with authoritative pricing and 30%-round-up advance.';

revoke all on function public.submit_customer_order_v1(text, date) from public, anon;
grant execute on function public.submit_customer_order_v1(text, date) to authenticated, service_role;
