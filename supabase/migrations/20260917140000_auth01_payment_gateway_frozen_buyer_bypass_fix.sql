-- AUTH-01 RPC security certification: close the same frozen/de-approved-
-- buyer bypass, already fixed for the final-payment-PI surface
-- (20260917130000), in the two payment-gateway RPCs.
--
-- create_payment_gateway_payable_intent_v1() and
-- get_payment_gateway_payable_status_v1() (both 20260907141000, never
-- redefined since) resolve the Buyer-side company via
-- public.auth_buyer_company_id() -- SELECT COALESCE(users.company_id,
-- profiles.company_id) WHERE id = auth.uid(), with no is_approved check,
-- no status check, no role filter, and no company active/not-frozen check.
--
-- This correctly prevents cross-company leakage (a buyer can only ever
-- resolve their own company_id) but does not prevent an inappropriate-actor
-- case: a buyer whose company was later frozen, or whose own profile was
-- later de-approved, keeps company_id on their profiles row and would
-- still pass the company-match check -- so they could still CREATE a
-- payment-gateway payable intent (a real money-movement action) and read
-- its status for that company's order, after the company was frozen.
--
-- Fix: swap auth_buyer_company_id() for customer_buyer_eligible_company_id()
-- in both functions' company-scope checks. The existing
-- `NOT is_internal_staff(...) AND ... IS DISTINCT FROM ...` structure is
-- preserved unchanged in both places -- staff access is untouched.
-- Narrowing-only for the buyer path (approved/active/not-frozen is a
-- strict subset of "has a company_id on file"), so it cannot newly allow
-- anything and cannot break a genuinely approved/active buyer's own
-- ability to pay.

create or replace function public.create_payment_gateway_payable_intent_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid,
  p_payment_purpose text,
  p_provider_code text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid default auth.uid()
) returns table(intent_id uuid, canonical_amount numeric, currency text, status text, already_created boolean)
language plpgsql security definer
set search_path = pg_catalog, public, auth, extensions
as $$
declare
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_order public.orders%rowtype;
  v_purpose text := lower(btrim(coalesce(p_payment_purpose, '')));
  v_provider text := lower(btrim(coalesce(p_provider_code, '')));
  v_existing public.payment_gateway_idempotency%rowtype;
  v_intent public.payment_gateway_payable_intents%rowtype;
  v_derived record;
  v_fingerprint text;
  v_response jsonb;
begin
  if auth.uid() is null or v_actor is distinct from auth.uid() then
    raise exception 'PAYMENT_GATEWAY_ACTOR_REQUIRED' using errcode = '42501';
  end if;
  select * into v_order from public.orders where id = p_order_id;
  if not found then raise exception 'PAYMENT_GATEWAY_ORDER_NOT_FOUND' using errcode = 'P0001'; end if;
  if not public.is_internal_staff(v_actor)
     and v_order.company_id is distinct from public.customer_buyer_eligible_company_id() then
    raise exception 'PAYMENT_GATEWAY_COMPANY_SCOPE_REQUIRED' using errcode = '42501';
  end if;
  if v_purpose not in ('advance','balance','final_payment')
     or v_provider not in ('razorpay','payu','cashfree','stripe','generic')
     or nullif(btrim(p_correlation_id), '') is null
     or nullif(btrim(p_idempotency_key), '') is null then
    raise exception 'PAYMENT_GATEWAY_INTENT_EVIDENCE_REQUIRED' using errcode = 'P0001';
  end if;
  v_role := coalesce(public.get_user_role(v_actor), case when public.is_internal_staff(v_actor) then 'unknown' else 'b2b_buyer' end);
  select * into v_derived from public.derive_payment_gateway_canonical_amount_v1(
    p_order_id, p_pi_id, p_commercial_version_id, v_purpose);
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'order_id', p_order_id, 'pi_id', p_pi_id, 'commercial_version_id', p_commercial_version_id,
    'payment_purpose', v_purpose, 'provider_code', v_provider, 'canonical_amount', v_derived.canonical_amount,
    'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  select * into v_existing from public.payment_gateway_idempotency where idempotency_key = btrim(p_idempotency_key) for update;
  if found then
    if v_existing.actor_id is distinct from v_actor or v_existing.request_fingerprint is distinct from v_fingerprint then
      raise exception 'PAYMENT_GATEWAY_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return query select
      (v_existing.response ->> 'intent_id')::uuid,
      (v_existing.response ->> 'canonical_amount')::numeric,
      v_existing.response ->> 'currency',
      v_existing.response ->> 'status',
      true;
    return;
  end if;
  insert into public.payment_gateway_payable_intents(
    order_id, company_id, proforma_invoice_id, commercial_version_id, payment_purpose, provider_code,
    canonical_amount, currency, status, facts_snapshot, expires_at, correlation_id, idempotency_key,
    created_by, created_role
  ) values (
    p_order_id, v_order.company_id, p_pi_id, p_commercial_version_id, v_purpose, v_provider,
    v_derived.canonical_amount, v_derived.currency, 'created', v_derived.facts_snapshot,
    statement_timestamp() + interval '30 minutes', btrim(p_correlation_id), btrim(p_idempotency_key),
    v_actor, v_role
  ) returning * into v_intent;
  v_response := jsonb_build_object(
    'intent_id', v_intent.id, 'canonical_amount', v_intent.canonical_amount,
    'currency', v_intent.currency, 'status', v_intent.status
  );
  insert into public.payment_gateway_idempotency(idempotency_key, operation, request_fingerprint, intent_id, actor_id, response)
  values (btrim(p_idempotency_key), 'CREATE_INTENT', v_fingerprint, v_intent.id, v_actor, v_response);
  return query select v_intent.id, v_intent.canonical_amount, v_intent.currency, v_intent.status, false;
end;
$$;
revoke all on function public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid) from public, anon, service_role;
grant execute on function public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid) to authenticated;

create or replace function public.get_payment_gateway_payable_status_v1(p_intent_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public, auth
as $$
declare v_intent public.payment_gateway_payable_intents%rowtype;
begin
  if auth.uid() is null then raise exception 'PAYMENT_GATEWAY_STATUS_AUTH_REQUIRED' using errcode = '42501'; end if;
  select * into v_intent from public.payment_gateway_payable_intents where id = p_intent_id;
  if not found then raise exception 'PAYMENT_GATEWAY_INTENT_NOT_FOUND' using errcode = 'P0001'; end if;
  if not public.is_internal_staff(auth.uid())
     and v_intent.company_id is distinct from public.customer_buyer_eligible_company_id() then
    raise exception 'PAYMENT_GATEWAY_COMPANY_SCOPE_REQUIRED' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'intent_id', v_intent.id, 'order_id', v_intent.order_id, 'payment_purpose', v_intent.payment_purpose,
    'provider_code', v_intent.provider_code, 'canonical_amount', v_intent.canonical_amount,
    'currency', v_intent.currency, 'status', v_intent.status, 'provider_order_id', v_intent.provider_order_id,
    'provider_payment_id', v_intent.provider_payment_id, 'order_payment_id', v_intent.order_payment_id,
    'expires_at', v_intent.expires_at, 'facts_as_of', statement_timestamp(), 'buyer_status_only', true
  );
end;
$$;
revoke all on function public.get_payment_gateway_payable_status_v1(uuid) from public, anon, service_role;
grant execute on function public.get_payment_gateway_payable_status_v1(uuid) to authenticated;
