-- Forward-sequenced Genie G3 contract. Old preview migration 20261116140000_genie_cart_receipt_forward_parity_v2.sql is retained as a ledger-only stub.
-- Must be safe on a clean database and the previously migrated, isolated Genie preview.
-- Forward-only repair of a Git-linked preview with an older copy of
-- 20261115160000_genie_cart_operation_id_v2.sql. In fresh replay the
-- column/function are already correct and the statements are idempotent.
alter table public.customer_genie_cart_operations
  add column if not exists existing_quantity numeric;

-- For an originally inserted row, the exact insert quantity is recorded.
-- For an originally conflicting MANUAL line the older preview lacks
-- historical observed quantity. Never guess its origin/quantity.
do $$
begin
  if exists (
    select 1 from public.customer_genie_cart_operations
    where inserted is false and existing_quantity is null
  ) then
    raise exception 'GENIE_FORWARD_MIGRATION_UNSAFE: legacy manual conflict receipts need controlled reconciliation';
  end if;
end;
$$;

update public.customer_genie_cart_operations
set existing_quantity = quantity
where inserted is true and existing_quantity is null;

alter table public.customer_genie_cart_operations
  alter column existing_quantity set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint c
    where c.conrelid='public.customer_genie_cart_operations'::regclass
      and c.contype='c'
      and pg_get_constraintdef(c.oid) ilike '%existing_quantity%'
  ) then
    alter table public.customer_genie_cart_operations
      add constraint customer_genie_cart_operations_existing_quantity_forward_positive
      check (existing_quantity > 0);
  end if;
end;
$$;

create or replace function public.add_customer_order_draft_line_genie_v2(
  p_product_id uuid,
  p_quantity numeric,
  p_operation_id uuid
)
returns table (
  draft_id uuid,
  line_id uuid,
  inserted boolean,
  replayed boolean,
  existing_quantity numeric,
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
  v_old public.customer_genie_cart_operations%rowtype;
  v_new record;
  v_live_draft public.customer_order_drafts%rowtype;
  v_line public.customer_order_draft_lines%rowtype;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required' using errcode = '28000';
  end if;
  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' using errcode = '42501';
  end if;
  if p_operation_id is null or p_product_id is null or p_quantity is null
     or p_quantity <= 0 or p_quantity = 'NaN'::numeric then
    raise exception 'VALIDATION_FAILED: operation, product and positive quantity are required';
  end if;

  -- Consistent company lock first (same lock ordering as all current Cart writes).
  perform pg_advisory_xact_lock(hashtextextended('customer_draft:' || v_company_id::text, 0));

  -- operation_id is globally unique, so the same ID can NEVER be reused in another
  -- company or by a successor account, even after a client-side scope switch.
  select * into v_old from public.customer_genie_cart_operations o
    where o.operation_id = p_operation_id for update;
  if found then
    if v_old.company_id is distinct from v_company_id
       or v_old.buyer_id is distinct from v_uid
       or v_old.product_id is distinct from p_product_id
       or v_old.quantity is distinct from p_quantity then
      raise exception 'GENIE_OPERATION_MISMATCH: operation scope or payload differs'
        using errcode = '42501';
    end if;

    select * into v_live_draft from public.customer_order_drafts d
      where d.id = v_old.draft_id and d.company_id = v_company_id
        and d.status = 'active';
    if not found then
      raise exception 'GENIE_OPERATION_STALE: original draft is no longer active';
    end if;

    -- An originally inserted line AND an originally pre-existing/manual line
    -- must still exist unchanged before replay can describe it as current.
    -- A changed manual Cart quantity is not the old conflict quantity.
    -- ON DELETE SET NULL makes deletion explicit and fails closed here.
    if v_old.draft_line_id is null then
      raise exception 'GENIE_OPERATION_STALE: original Cart line has been removed';
    end if;
    select * into v_line from public.customer_order_draft_lines l
      where l.id = v_old.draft_line_id and l.draft_id = v_old.draft_id
        and l.product_id = v_old.product_id
        and l.quantity = v_old.existing_quantity;
    if not found then
      raise exception 'GENIE_OPERATION_STALE: original Cart line changed; reconcile in Cart';
    end if;

    return query select v_old.draft_id, v_old.draft_line_id,
      v_old.inserted, true, v_old.existing_quantity,
      v_live_draft.readiness_status, v_live_draft.readiness_issues;
    return;
  end if;

  -- v1 performs server-authoritative product, pricing, MOQ, carton, auth,
  -- draft locks, readiness and audit. The nested call and receipt share the
  -- same transaction; receipt failures roll the Cart mutation back.
  select * into v_new
    from public.add_customer_order_draft_line_if_absent_v1(p_product_id, p_quantity);
  if not found or v_new.draft_id is null or v_new.line_id is null then
    raise exception 'GENIE_INSERT_UNCONFIRMED: Core returned no authoritative draft line';
  end if;

  insert into public.customer_genie_cart_operations (
    operation_id, company_id, buyer_id, draft_id, draft_line_id,
    product_id, quantity, existing_quantity, inserted
  ) values (
    p_operation_id, v_company_id, v_uid, v_new.draft_id, v_new.line_id,
    p_product_id, p_quantity, v_new.existing_quantity, v_new.inserted
  );

  return query select v_new.draft_id::uuid, v_new.line_id::uuid,
    v_new.inserted::boolean, false, v_new.existing_quantity::numeric,
    v_new.readiness_status::text, v_new.readiness_issues::jsonb;
end;
$$;

comment on function public.add_customer_order_draft_line_genie_v2(uuid, numeric, uuid) is
  'Genie server-scoped operation-ID retry receipt. Identity and insert commit atomically; replay never adopts a matching manual Cart line.';
revoke all on function public.add_customer_order_draft_line_genie_v2(uuid, numeric, uuid)
  from public, anon;
grant execute on function public.add_customer_order_draft_line_genie_v2(uuid, numeric, uuid)
  to authenticated, service_role;
