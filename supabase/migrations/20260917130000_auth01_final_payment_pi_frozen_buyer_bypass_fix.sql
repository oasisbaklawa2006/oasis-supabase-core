-- AUTH-01 RPC security certification: close a frozen/de-approved-buyer
-- bypass in the final-payment-PI surface.
--
-- get_sales_order_pi_final_payment_request_v1() and the three RLS policies
-- governing sales_order_pi_final_payment_requests /
-- sales_order_pi_final_payment_request_audit /
-- sales_order_pi_final_payment_request_deliveries (all defined
-- 20260902083000, never redefined since) resolve the caller's company via
-- public.auth_buyer_company_id() -- a much weaker helper than the canonical
-- public.customer_buyer_eligible_company_id() used everywhere else this
-- audit checked. auth_buyer_company_id() is:
--
--   SELECT COALESCE(
--     (SELECT u.company_id FROM public.users u WHERE u.id = auth.uid()),
--     (SELECT p.company_id FROM public.profiles p WHERE p.id = auth.uid())
--   );
--
-- It has NO is_approved check, NO status check, NO role filter, and NO
-- company active/not-frozen check -- it returns whatever company_id sits on
-- the caller's own row, unconditionally. It correctly prevents CROSS-company
-- leakage (a buyer can only ever get their own company's id back), but it
-- does not prevent an INAPPROPRIATE-ACTOR case: a buyer whose company was
-- later frozen, or whose own profile was later de-approved/suspended after
-- initially being approved, keeps their company_id on file and would still
-- pass `o.company_id IS DISTINCT FROM auth_buyer_company_id()` -- so they
-- could still read final-payment-request details (payment link, payment
-- instructions, balance due, document reference) for that company's orders,
-- exactly the kind of access customer_buyer_eligible_company_id() exists to
-- deny once a company is frozen or a buyer is no longer approved.
--
-- Fix: swap auth_buyer_company_id() for customer_buyer_eligible_company_id()
-- in this one RPC and its three governing RLS policies only. The existing
-- `is_internal_staff(...) OR ...` structure is preserved unchanged in all
-- four places -- staff access is untouched. This is narrowing-only for the
-- buyer path (approved/active/not-frozen is a strict subset of "has a
-- company_id on file"), so it cannot newly allow anything and cannot break
-- a genuinely approved, active buyer's access to their own final payment
-- requests.
--
-- Scope note: public.auth_buyer_company_id() itself is left unmodified, and
-- its other call sites elsewhere in Core (outside today's Buyer App RPC
-- allowlist) are NOT audited or changed here -- that is explicitly a
-- Finance/Orders-lane concern outside this AUTH-01 certification pass and
-- is recorded as a follow-up recommendation rather than fixed in place.

create or replace function public.get_sales_order_pi_final_payment_request_v1(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_order public.orders%rowtype;
  v_request public.sales_order_pi_final_payment_requests%rowtype;
  v_coverage jsonb;
  v_latest_delivery jsonb;
  v_effective_status text;
begin
  if auth.uid() is null then
    raise exception 'FINAL_PAYMENT_PI_AUTHENTICATION_REQUIRED' using errcode='42501';
  end if;
  select * into v_order from public.orders where id=p_order_id;
  if not found then raise exception 'FINAL_PAYMENT_PI_ORDER_NOT_FOUND' using errcode='P0001'; end if;
  if not public.is_internal_staff(auth.uid())
     and v_order.company_id is distinct from public.customer_buyer_eligible_company_id() then
    raise exception 'FINAL_PAYMENT_PI_COMPANY_MISMATCH' using errcode='42501';
  end if;

  select * into v_request
    from public.sales_order_pi_final_payment_requests
   where order_id=p_order_id
   order by revision_number desc
   limit 1;
  if not found then
    return jsonb_build_object(
      'order_id',p_order_id,
      'available',false,
      'final_payment_request',null
    );
  end if;

  v_coverage:=public.get_sales_order_final_payment_coverage_v1(
    v_request.order_id,v_request.proforma_invoice_id,v_request.commercial_version_id,
    v_request.final_payable_total
  );
  v_effective_status:=case when (v_coverage->>'settled')::boolean then 'SETTLED' else 'PAYMENT_DUE' end;

  select jsonb_build_object(
    'delivery_id',d.id,
    'channel',d.channel,
    'destination_reference',d.destination_reference,
    'provider_message_id',d.provider_message_id,
    'delivery_status',d.delivery_status,
    'evidence_reference',d.evidence_reference,
    'delivered_at',d.delivered_at,
    'created_at',d.created_at
  ) into v_latest_delivery
  from public.sales_order_pi_final_payment_request_deliveries d
  where d.final_payment_request_id=v_request.id
  order by d.created_at desc,d.id desc
  limit 1;

  return jsonb_build_object(
    'order_id',v_request.order_id,
    'company_id',v_request.company_id,
    'available',true,
    'final_payment_request_id',v_request.id,
    'pi_id',v_request.proforma_invoice_id,
    'customer_visible_pi_number',v_request.customer_visible_pi_number,
    'revision_number',v_request.revision_number,
    'effective_status',v_effective_status,
    'finance_dpl_receipt_id',v_request.finance_dpl_receipt_id,
    'commercial_version_id',v_request.commercial_version_id,
    'dpl_fingerprint',v_request.dpl_fingerprint,
    'currency',v_request.currency,
    'taxable_total',v_request.taxable_total,
    'tax_total',v_request.tax_total,
    'final_payable_total',v_request.final_payable_total,
    'verified_payment_total',(v_coverage->>'verified_payment_total')::numeric,
    'wallet_applied_total',(v_coverage->>'wallet_applied_total')::numeric,
    'approved_credit_total',(v_coverage->>'approved_credit_total')::numeric,
    'credited_or_paid_total',(v_coverage->>'credited_or_paid_total')::numeric,
    'balance_due',(v_coverage->>'balance_due')::numeric,
    'settled',(v_coverage->>'settled')::boolean,
    'payment_action',v_request.payment_action,
    'payment_link',v_request.payment_link,
    'payment_instructions',v_request.payment_instructions,
    'document_reference',v_request.document_reference,
    'reason',v_request.reason,
    'source_channel',v_request.source_channel,
    'source_reference',v_request.source_reference,
    'issued_at',v_request.issued_at,
    'latest_delivery',v_latest_delivery,
    'facts_as_of',v_coverage->'facts_as_of',
    'final_invoice_must_not_request_payment',true
  );
end;
$$;

revoke all on function public.get_sales_order_pi_final_payment_request_v1(uuid)
  from public, anon;
grant execute on function public.get_sales_order_pi_final_payment_request_v1(uuid)
  to authenticated, service_role;

drop policy if exists sales_order_pi_final_payment_requests_read
  on public.sales_order_pi_final_payment_requests;
create policy sales_order_pi_final_payment_requests_read
  on public.sales_order_pi_final_payment_requests for select to authenticated
  using (
    public.is_internal_staff(auth.uid())
    or exists (
      select 1 from public.orders o
       where o.id = sales_order_pi_final_payment_requests.order_id
         and o.company_id = public.customer_buyer_eligible_company_id()
    )
  );

drop policy if exists sales_order_pi_final_payment_request_audit_read
  on public.sales_order_pi_final_payment_request_audit;
create policy sales_order_pi_final_payment_request_audit_read
  on public.sales_order_pi_final_payment_request_audit for select to authenticated
  using (
    public.is_internal_staff(auth.uid())
    or exists (
      select 1 from public.orders o
       where o.id = sales_order_pi_final_payment_request_audit.order_id
         and o.company_id = public.customer_buyer_eligible_company_id()
    )
  );

drop policy if exists sales_order_pi_final_payment_request_deliveries_read
  on public.sales_order_pi_final_payment_request_deliveries;
create policy sales_order_pi_final_payment_request_deliveries_read
  on public.sales_order_pi_final_payment_request_deliveries for select to authenticated
  using (
    public.is_internal_staff(auth.uid())
    or exists (
      select 1
        from public.sales_order_pi_final_payment_requests r
        join public.orders o on o.id = r.order_id
       where r.id = sales_order_pi_final_payment_request_deliveries.final_payment_request_id
         and o.company_id = public.customer_buyer_eligible_company_id()
    )
  );
