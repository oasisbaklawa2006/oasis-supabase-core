-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260818010100_whatsapp_case_identity_wa3_bridge.sql (head 3b013b4); full diff performed -- candidate adds one COMMENT ON FUNCTION clause only.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- Bridge a human-confirmed communication-case customer identity into WA-3's
-- canonical client_identity resolution through the governed evidence RPC.
-- This is intentionally event-driven so the existing confirmation RPC remains
-- the sole human action boundary while WA-3 remains the order-field authority.

create or replace function public.bridge_whatsapp_case_identity_to_wa3()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_case public.whatsapp_communication_cases%rowtype;
  v_potential_order public.whatsapp_potential_orders%rowtype;
  v_company public.companies%rowtype;
  v_company_id uuid;
  v_potential_order_id uuid;
begin
  if new.event_type <> 'CASE_IDENTITY_CONFIRMED' then
    return new;
  end if;

  if new.actor_type <> 'OPERATOR' or new.actor_id is null or auth.uid() is distinct from new.actor_id then
    raise exception 'case identity bridge requires the same authenticated operator';
  end if;

  if not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WhatsApp triage permission required for WA3 identity bridge' using errcode = '42501';
  end if;

  begin
    v_company_id := nullif(new.resulting_state ->> 'company_id', '')::uuid;
  exception when invalid_text_representation then
    v_company_id := null;
  end;

  if v_company_id is null then
    raise exception 'confirmed case identity event is missing company_id';
  end if;

  select * into v_case
  from public.whatsapp_communication_cases
  where id = new.case_id;

  if not found or v_case.company_id is distinct from v_company_id then
    raise exception 'confirmed case company does not match identity event';
  end if;

  v_potential_order_id := public.whatsapp_case_potential_order_id(new.case_id);
  if v_potential_order_id is null then
    return new;
  end if;

  select * into v_potential_order
  from public.whatsapp_potential_orders
  where id = v_potential_order_id;

  if not found then
    raise exception 'governed potential order not found for case identity bridge';
  end if;

  -- A closed/superseded commercial object must not be re-opened by identity work.
  -- Non-active objects therefore remain case-only and WA-6 continues to fail closed.
  if v_potential_order.disposition <> 'ACTIVE_PENDING' then
    return new;
  end if;

  select * into v_company from public.companies where id = v_company_id;
  if not found then raise exception 'confirmed B2B company no longer exists'; end if;

  perform public.record_whatsapp_order_field_evidence(
    v_potential_order.id,
    'client_identity',
    v_potential_order.source_message_id,
    'case-identity:' || new.correlation_key,
    jsonb_build_object('company_id', v_company.id),
    'operator_confirmation',
    1.0,
    v_company.business_name,
    jsonb_build_object(
      'case_id', new.case_id,
      'case_identity_event_id', new.id,
      'verification_method', coalesce(new.metadata ->> 'verification_method', 'OPERATOR_VERIFIED'),
      'authority', 'WA3_GOVERNED_EVIDENCE_RPC'
    ),
    true
  );

  return new;
end;
$$;

comment on function public.bridge_whatsapp_case_identity_to_wa3() is
  'After CASE_IDENTITY_CONFIRMED, routes the same human decision through WA-3 record_whatsapp_order_field_evidence for canonical client_identity authority. It never directly writes WA-3 resolution state.';

revoke all on function public.bridge_whatsapp_case_identity_to_wa3() from public, anon, authenticated;

create trigger whatsapp_case_identity_to_wa3_bridge
after insert on public.whatsapp_case_events
for each row
when (new.event_type = 'CASE_IDENTITY_CONFIRMED')
execute function public.bridge_whatsapp_case_identity_to_wa3();
