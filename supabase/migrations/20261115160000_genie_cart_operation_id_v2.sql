-- Genie G3 recovery (Core #535): durable, transactionally bound identity for a Cart insert.
-- Additive: existing add_customer_order_draft_line_if_absent_v1 callers and contract are untouched.
-- The operation row and the actual Cart mutation commit or roll back in ONE PostgreSQL transaction.
create table public.customer_genie_cart_operations (
  operation_id uuid primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  buyer_id uuid not null references auth.users(id) on delete cascade,
  draft_id uuid not null references public.customer_order_drafts(id) on delete cascade,
  draft_line_id uuid references public.customer_order_draft_lines(id) on delete set null,
  product_id uuid not null references public.products(id),
  quantity numeric not null check (quantity > 0),
  existing_quantity numeric not null check (existing_quantity > 0),
  inserted boolean not null,
  created_at timestamptz not null default now()
);

create index customer_genie_cart_operations_buyer_scope_idx
  on public.customer_genie_cart_operations(company_id, buyer_id, created_at desc);

alter table public.customer_genie_cart_operations enable row level security;
-- No client may read or mutate this provenance table directly. Only the scoped RPC below.
revoke all on table public.customer_genie_cart_operations from public, anon, authenticated;
comment on table public.customer_genie_cart_operations is
  'Server-authoritative Genie operation receipts; no direct client access. A receipt is committed in the same transaction as the Cart insert.';

create function public.add_customer_order_draft_line_genie_v2(
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

    if v_old.inserted then
      select * into v_line from public.customer_order_draft_lines l
        where l.id = v_old.draft_line_id and l.draft_id = v_old.draft_id
          and l.product_id = v_old.product_id and l.quantity = v_old.quantity;
      if not found then
        -- Never claim a removed/modified Cart line as still successfully present.
        raise exception 'GENIE_OPERATION_STALE: original line has changed; reconcile in Cart';
      end if;
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
