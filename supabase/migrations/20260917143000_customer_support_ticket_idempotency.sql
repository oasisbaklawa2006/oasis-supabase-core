begin;

alter table public.support_tickets
  add column idempotency_key text;

alter table public.support_tickets
  add constraint support_tickets_idempotency_key_length
  check (
    idempotency_key is null
    or (length(btrim(idempotency_key)) between 1 and 200)
  );

create unique index support_tickets_buyer_idempotency_uidx
  on public.support_tickets(company_id, user_id, idempotency_key)
  where idempotency_key is not null;

-- Replace the legacy non-idempotent buyer mutation. This is deliberately a
-- signature change: production release must not occur until the Buyer client
-- has moved to the new contract, so old clients cannot silently keep creating
-- duplicate support tickets after response loss/retry.
drop function if exists public.submit_customer_support_ticket_v1(uuid,text,text,text,integer);

create function public.submit_customer_support_ticket_v1(
  p_idempotency_key text,
  p_order_id uuid,
  p_issue_type text,
  p_description text,
  p_product_sku text default null,
  p_quantity_affected integer default null
)
returns table(
  ticket_id uuid,
  status text,
  is_duplicate_submission boolean
)
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_company_id uuid := public.customer_buyer_eligible_company_id();
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_issue_type text := lower(replace(btrim(coalesce(p_issue_type, '')), ' ', '_'));
  v_description text := btrim(coalesce(p_description, ''));
  v_product_sku text := nullif(btrim(coalesce(p_product_sku, '')), '');
  v_existing public.support_tickets%rowtype;
begin
  if v_uid is null or v_company_id is null then
    raise exception 'SUPPORT_TICKET_BUYER_CONTEXT_REQUIRED' using errcode='42501';
  end if;

  if v_key = '' or length(v_key) > 200 then
    raise exception 'SUPPORT_TICKET_IDEMPOTENCY_KEY_REQUIRED' using errcode='22023';
  end if;

  if p_order_id is null then
    raise exception 'SUPPORT_TICKET_ORDER_REQUIRED' using errcode='22023';
  end if;

  if v_issue_type = '' then
    raise exception 'SUPPORT_TICKET_ISSUE_TYPE_REQUIRED' using errcode='22023';
  end if;

  if length(v_description) < 10 or length(v_description) > 4000 then
    raise exception 'SUPPORT_TICKET_DESCRIPTION_INVALID' using errcode='22023';
  end if;

  if p_quantity_affected is not null and p_quantity_affected <= 0 then
    raise exception 'SUPPORT_TICKET_QUANTITY_INVALID' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'customer-support-ticket:' || v_company_id::text || ':' || v_uid::text || ':' || v_key,
    0
  ));

  select *
  into v_existing
  from public.support_tickets t
  where t.company_id = v_company_id
    and t.user_id = v_uid
    and t.idempotency_key = v_key;

  if found then
    if v_existing.order_id is distinct from p_order_id::text
       or v_existing.issue_type is distinct from v_issue_type
       or v_existing.description is distinct from v_description
       or v_existing.product_sku is distinct from v_product_sku
       or v_existing.qty_affected is distinct from p_quantity_affected then
      raise exception 'SUPPORT_TICKET_IDEMPOTENCY_CONFLICT' using errcode='23505';
    end if;

    return query
      select v_existing.id, coalesce(v_existing.status, 'open'), true;
    return;
  end if;

  insert into public.support_tickets (
    order_id,
    issue_type,
    description,
    product_sku,
    qty_affected,
    status,
    idempotency_key
  ) values (
    p_order_id::text,
    v_issue_type,
    v_description,
    v_product_sku,
    p_quantity_affected,
    'open',
    v_key
  )
  returning * into v_existing;

  return query
    select v_existing.id, coalesce(v_existing.status, 'open'), false;
end;
$$;

revoke all on function public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)
  from public, anon;
grant execute on function public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)
  to authenticated, service_role;

comment on column public.support_tickets.idempotency_key is
  'Buyer-supplied stable retry key. Unique per company/user when present; legacy rows remain null.';
comment on function public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer) is
  'Exactly-once buyer support-ticket submission. Same key+payload replays the canonical ticket; same key+different payload fails closed.';

commit;
