-- Reconcile the exact orphaned DPL/carton duplicate observed in production.
--
-- This migration intentionally precedes 20260814121200 so Gate 3 authority
-- closure can create its single-membership indexes. It is fail-closed: any
-- deviation from the verified production fingerprint aborts the migration.
-- The superseded DPL document is retained and marked cancelled for audit;
-- only its unreferenced duplicate carton membership is removed.

do $$
declare
  v_carton_id constant uuid := 'a847cf72-3c10-4eb4-b183-23e88fe3c710';
  v_keep_dpl_id constant uuid := '7ac59281-209a-4508-a09a-b397d798683d';
  v_duplicate_dpl_id constant uuid := '1a0974b0-4138-4543-97c8-1ce163f115e0';
  v_duplicate_membership_id constant uuid := '06fd4f81-0b6f-4432-ad97-26a1be80fedb';
  v_deleted integer;
  v_cancelled integer;
begin
  -- A replay on a database without this production-only anomaly is a no-op.
  if not exists (
    select 1
    from public.ols_dpl_cartons
    where carton_id = v_carton_id
      and dpl_id = v_duplicate_dpl_id
  ) then
    if exists (
      select 1
      from public.ols_dpl_cartons
      group by carton_id
      having count(*) > 1
    ) then
      raise exception 'TRACE_DPL_DUPLICATE_FINGERPRINT_MISMATCH: expected duplicate is absent but another carton duplicate exists'
        using errcode = 'P0001';
    end if;
    return;
  end if;

  -- Require the exact two verified memberships and no additional claim.
  if not exists (
    select 1 from public.ols_dpl_cartons
    where id = 'da96ad16-ecb2-4ce9-8620-fb6ebab1b184'
      and dpl_id = v_keep_dpl_id
      and carton_id = v_carton_id
      and position = 1
  ) or not exists (
    select 1 from public.ols_dpl_cartons
    where id = v_duplicate_membership_id
      and dpl_id = v_duplicate_dpl_id
      and carton_id = v_carton_id
      and position = 1
  ) or 2 <> (
    select count(*) from public.ols_dpl_cartons where carton_id = v_carton_id
  ) then
    raise exception 'TRACE_DPL_DUPLICATE_FINGERPRINT_MISMATCH: carton membership rows differ from verified evidence'
      using errcode = 'P0001';
  end if;

  -- Both DPLs must be the same open shipment, with the earlier record kept.
  if not exists (
    select 1
    from public.ols_dpl_documents keep_dpl
    join public.ols_dpl_documents duplicate_dpl
      on duplicate_dpl.id = v_duplicate_dpl_id
    where keep_dpl.id = v_keep_dpl_id
      and keep_dpl.dpl_no = 'DPL-20260511-266'
      and keep_dpl.order_ref = 'SO-2026-0002'
      and keep_dpl.customer_name = 'Gulf Sweets LLC'
      and keep_dpl.destination = 'Abu Dhabi'
      and keep_dpl.transport_mode = 'Truck'
      and keep_dpl.status = 'open'
      and duplicate_dpl.dpl_no = 'DPL-20260511-178'
      and duplicate_dpl.order_ref = 'SO-2026-0002'
      and duplicate_dpl.customer_name = 'Gulf Sweets LLC'
      and duplicate_dpl.destination = 'Abu Dhabi'
      and duplicate_dpl.transport_mode = 'Truck'
      and duplicate_dpl.status = 'open'
      and keep_dpl.created_at < duplicate_dpl.created_at
  ) then
    raise exception 'TRACE_DPL_DUPLICATE_FINGERPRINT_MISMATCH: DPL documents differ from verified evidence'
      using errcode = 'P0001';
  end if;

  -- Do not reconcile a duplicate that has acquired downstream business use.
  if exists (select 1 from public.ols_finance_pi where dpl_id in (v_keep_dpl_id, v_duplicate_dpl_id))
     or exists (select 1 from public.ols_dispatch_document_bundles where dpl_id in (v_keep_dpl_id, v_duplicate_dpl_id))
     or exists (select 1 from public.ols_finance_pi_cartons where carton_id = v_carton_id)
     or exists (select 1 from public.ols_shipping_labels where carton_id = v_carton_id) then
    raise exception 'TRACE_DPL_DUPLICATE_HAS_DOWNSTREAM_REFERENCES: manual review required'
      using errcode = 'P0001';
  end if;

  delete from public.ols_dpl_cartons
  where id = v_duplicate_membership_id
    and dpl_id = v_duplicate_dpl_id
    and carton_id = v_carton_id;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 1 then
    raise exception 'TRACE_DPL_DUPLICATE_REMEDIATION_FAILED: membership row was not removed'
      using errcode = 'P0001';
  end if;

  update public.ols_dpl_documents
  set status = 'cancelled',
      remarks = concat_ws(' | ', nullif(remarks, ''), 'Cancelled as duplicate of DPL-20260511-266 by 20260814121150 reconciliation')
  where id = v_duplicate_dpl_id
    and status = 'open';
  get diagnostics v_cancelled = row_count;
  if v_cancelled <> 1 then
    raise exception 'TRACE_DPL_DUPLICATE_REMEDIATION_FAILED: duplicate DPL was not cancelled'
      using errcode = 'P0001';
  end if;

  insert into public.ols_audit_logs(action, entity_type, entity_id, user_id, details)
  values (
    'trace_dpl_duplicate_membership_reconciled',
    'dpl_carton_membership',
    v_duplicate_membership_id,
    null,
    jsonb_build_object(
      'carton_id', v_carton_id,
      'retained_dpl_id', v_keep_dpl_id,
      'cancelled_dpl_id', v_duplicate_dpl_id,
      'reason', 'exact duplicate open DPL for same SO/customer/destination with no downstream references'
    )
  );
end $$;
