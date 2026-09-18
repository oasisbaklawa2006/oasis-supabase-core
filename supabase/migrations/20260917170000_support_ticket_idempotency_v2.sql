-- Adds submit_customer_support_ticket_v2, a new, idempotent ticket
-- submission RPC, modeled directly on submit_customer_general_query_v1's
-- already-proven pattern. Backward-compatible rollout, per governed
-- release requirements:
--
--   submit_customer_support_ticket_v1(p_order_id, p_issue_type,
--     p_description, p_product_sku, p_quantity_affected) is left
--     COMPLETELY UNCHANGED -- same signature, same body, same grants. Any
--     currently-deployed Buyer build keeps working exactly as before.
--   submit_customer_support_ticket_v2(p_idempotency_key, p_order_id,
--     p_issue_type, p_description, p_product_sku, p_quantity_affected) is
--     new, with the idempotency protection v1 has always lacked.
--
-- Deployment order this migration assumes (not enforced by SQL, an
-- operational requirement): (A) this migration lands and is certified;
-- (B) existing production clients keep calling v1, unaffected; (C) a new
-- Buyer release that calls v2 is certified and rolled out; (D) v1 removal
-- is evaluated only later, after old-client retirement, as its own
-- separate governed change -- not part of this migration.
--
-- Found during a Buyer-app bugsweep: unlike checkout, quotation accept/
-- decline, and general queries -- every one of which has an idempotency
-- key, an advisory lock, and a same-key/same-payload dedup path -- v1 has
-- none of that. Client-side double-tap protection exists (a
-- disabled-while-submitting button), but retry-after-timeout, a dropped
-- response after the server already committed, or an app kill mid-
-- submission had no server-side protection: each could create a genuine
-- duplicate ticket. v2 exists to close that gap for new Buyer releases
-- without breaking anything already deployed.

alter table public.support_tickets
  add column if not exists idempotency_key text;

-- One ticket per (company, user, key) -- same scoping as
-- customer_general_queries' natural key. Partial (idempotency_key is not
-- null) because v1-created rows, and any other insert path into this
-- table (e.g. staff-created tickets), never populate it.
create unique index if not exists support_tickets_company_user_idempotency_key_idx
  on public.support_tickets (company_id, created_by, idempotency_key)
  where idempotency_key is not null;

create or replace function public.submit_customer_support_ticket_v2(
  p_idempotency_key text,
  p_order_id uuid,
  p_issue_type text,
  p_description text,
  p_product_sku text default null,
  p_quantity_affected integer default null
) returns table (ticket_id uuid, is_duplicate_submission boolean)
language plpgsql
security definer
set search_path to pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_issue_type text;
  v_description text := btrim(coalesce(p_description, ''));
  v_new_ticket_id uuid;
  v_existing public.support_tickets%rowtype;
  v_company_id uuid;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication required' using errcode = '28000';
  end if;

  if v_key = '' or length(v_key) > 200 then
    raise exception 'SUPPORT_TICKET_IDEMPOTENCY_KEY_REQUIRED' using errcode = '22023';
  end if;

  if nullif(btrim(p_issue_type), '') is null then
    raise exception 'issue type is required';
  end if;
  v_issue_type := lower(replace(btrim(p_issue_type), ' ', '_'));

  if v_description is null or length(v_description) < 10 then
    raise exception 'description must contain at least 10 characters';
  end if;

  if length(v_description) > 4000 then
    raise exception 'description exceeds 4000 characters';
  end if;

  if p_quantity_affected is not null and p_quantity_affected <= 0 then
    raise exception 'quantity affected must be positive';
  end if;

  -- Company context for the lock/dedup key only -- the authoritative
  -- order-ownership and company/status checks remain entirely owned by
  -- the existing support_ticket_set_customer_context() BEFORE INSERT
  -- trigger, shared with v1 and unchanged by this migration. v2 does not
  -- duplicate or weaken that logic; customer_buyer_eligible_company_id()
  -- here is only used to scope the advisory lock and the dedup lookup,
  -- consistently with every other idempotent customer-app RPC.
  --
  -- Side effect (strictly narrowing, not a regression, and specific to
  -- v2 -- v1 is completely unaffected): for a genuinely approved buyer
  -- this resolves to the same company as the trigger's own derivation.
  -- For the edge-case staff-shaped profile documented in
  -- 20260917150000_support_ticket_context_trigger_no_impact_assertion.sql
  -- (is_approved/status='approved'/company_id set on a staff profile),
  -- customer_buyer_eligible_company_id() explicitly excludes staff and
  -- returns null, so v2 rejects that caller with
  -- SUPPORT_TICKET_BUYER_CONTEXT_REQUIRED before ever reaching the
  -- trigger's more permissive path -- an incidental further restriction
  -- on the v2 path only, not a new permission on either version.
  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'SUPPORT_TICKET_BUYER_CONTEXT_REQUIRED' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('customer-support-ticket-v2:' || v_company_id::text || ':' || v_uid::text || ':' || v_key, 0)
  );

  select * into v_existing
  from public.support_tickets
  where company_id = v_company_id
    and created_by = v_uid
    and idempotency_key = v_key;

  if found then
    if v_existing.order_id is distinct from p_order_id::text
       or v_existing.issue_type is distinct from v_issue_type
       or v_existing.description is distinct from v_description
       or v_existing.product_sku is distinct from nullif(btrim(p_product_sku), '')
       or v_existing.qty_affected is distinct from p_quantity_affected then
      -- Deliberately NOT errcode 23505 here: this function also has an
      -- `exception when unique_violation` handler below (a genuine
      -- belt-and-suspenders safety net for the true concurrent-race case).
      -- Reusing 23505 for both meant this raise was caught by that SAME
      -- handler and silently swallowed -- caught by actually running this
      -- in a real Postgres instance, not assumed correct by
      -- pattern-matching submit_customer_general_query_v1. P0001 reaches
      -- the caller as intended.
      raise exception 'SUPPORT_TICKET_IDEMPOTENCY_CONFLICT' using errcode = 'P0001';
    end if;
    return query select v_existing.id, true;
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
    nullif(btrim(p_product_sku), ''),
    p_quantity_affected,
    'open',
    v_key
  )
  returning id into v_new_ticket_id;

  return query select v_new_ticket_id, false;
exception
  when unique_violation then
    select * into v_existing
    from public.support_tickets
    where company_id = v_company_id
      and created_by = v_uid
      and idempotency_key = v_key;
    if not found then
      raise;
    end if;
    return query select v_existing.id, true;
end;
$$;

comment on function public.submit_customer_support_ticket_v2(text, uuid, text, text, text, integer) is
  'Idempotent successor to submit_customer_support_ticket_v1: same order-ownership authority (shared support_ticket_set_customer_context trigger, unchanged), plus a required p_idempotency_key with the same advisory-lock/dedup pattern as submit_customer_general_query_v1. v1 remains deployed, unchanged, for existing clients; new Buyer releases call v2.';

-- Identical grant scope to v1 -- authenticated buyers only, no anon, no
-- privilege expansion relative to what v1 already allowed.
revoke all on function public.submit_customer_support_ticket_v2(text, uuid, text, text, text, integer)
  from public, anon;
grant execute on function public.submit_customer_support_ticket_v2(text, uuid, text, text, text, integer)
  to authenticated;
