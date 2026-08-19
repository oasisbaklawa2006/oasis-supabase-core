-- Forward-only defect closure: WhatsApp normalization and runtime
-- correctness. Closes one defect surfaced by PR #89 review and deliberately
-- deferred; reclassifies a second as a false positive after re-auditing it
-- against the live schema. Documented in
-- docs/reconciliation/production-migration-lineage-recovery-2026-08-18.md
-- under "Pre-existing production bugs surfaced by review".
--
-- The phone-normalization regex bug ('\\D' escaped-backslash literal,
-- Codacy-surfaced) in whatsapp_release_case_reply and
-- whatsapp_release_reviewed_case_reply is already closed by the preceding
-- WA authority/security hardening migration in this same PR, since both
-- functions also needed a disclosure_scope fix in the same CREATE OR
-- REPLACE body.
--
-- RE-AUDITED, RECLASSIFIED FALSE_POSITIVE, NOT CHANGED:
-- whatsapp_decide_case_proposed_change compares
-- `whatsapp_messages.created_at >= (v_change.created_at at time zone 'UTC')`.
-- PR #89 review read this as reintroducing session-TimeZone dependence,
-- reasoning that whatsapp_messages.created_at is timestamptz. Checked
-- directly against the live production catalog before writing this
-- migration: whatsapp_messages.created_at is actually `timestamp WITHOUT
-- time zone` (whatsapp_case_proposed_changes.created_at is the timestamptz
-- side). `timestamptz AT TIME ZONE 'UTC'` deterministically converts to a
-- UTC-naive timestamp regardless of session TimeZone, and comparing that
-- against another naive timestamp column involves no further timezone
-- conversion at all -- the existing code is the timezone-safe form. Removing
-- the conversion, as the review suggested, would instead compare a naive
-- timestamp against a timestamptz directly, which PostgreSQL resolves by
-- implicitly casting the naive side up to timestamptz *using the session's
-- current TimeZone* -- reintroducing exactly the session-TimeZone-dependent
-- bug the review was trying to close. Left unchanged.

-- =================================================================================
-- 1. capture_whatsapp_payment_proof_evidence: the payment-evidence hash uses
--    an unqualified `digest(...)` call. pgcrypto is created in the
--    `extensions` schema (20260723161256_legacy_role_authority_baseline.sql)
--    but this function's search_path is pg_catalog, public, auth -- it does
--    not include extensions, so `digest` is unresolved/ambiguous depending
--    on session state rather than deterministically resolving to pgcrypto's
--    digest(). Qualify the call explicitly.
--
-- Full definition reproduced from the last (only) effective version
-- (supabase/migrations/20260817211036_whatsapp_payment_proof_governance.sql)
-- with only the digest() call qualified.
-- =================================================================================

create or replace function public.capture_whatsapp_payment_proof_evidence(
  p_case_id uuid,
  p_source_message_id uuid,
  p_detected_by text,
  p_claimed_amount numeric,
  p_claimed_reference text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_role text:=coalesce(auth.jwt()->>'role','');
  v_detector text:=upper(btrim(coalesce(p_detected_by,'')));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_case public.whatsapp_communication_cases%rowtype;
  v_message public.whatsapp_messages%rowtype;
  v_restricted public.whatsapp_case_restricted_evidence%rowtype;
  v_proof public.whatsapp_case_payment_proofs%rowtype;
  v_hash text;
begin
  if v_detector not in ('AI','OPERATOR') then raise exception 'unsupported payment evidence detector'; end if;
  if v_detector='AI' then
    if v_role<>'service_role' then raise exception 'trusted AI processor required' using errcode='42501'; end if;
  else
    if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
      raise exception 'WhatsApp triage permission required' using errcode='42501';
    end if;
  end if;
  if p_claimed_amount is not null and p_claimed_amount<=0 then raise exception 'claimed amount must be positive'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  select * into v_message from public.whatsapp_messages
  where id=p_source_message_id and packet_id=v_case.packet_id and direction='inbound';
  if not found then raise exception 'payment evidence source must be an inbound message in the same packet'; end if;

  select * into v_proof from public.whatsapp_case_payment_proofs
  where case_id=p_case_id and correlation_key='payment-proof:'||v_key;
  if found then return jsonb_build_object('case_id',p_case_id,'payment_proof_id',v_proof.id,'receipt_status',v_proof.receipt_status,'idempotent_replay',true); end if;

  v_hash:=encode(extensions.digest(p_case_id::text||':'||p_source_message_id::text||':'||coalesce(v_message.provider_message_id,''),'sha256'),'hex');
  insert into public.whatsapp_case_restricted_evidence(
    case_id,source_message_id,evidence_type,storage_reference,content_hash,public_mask,
    quarantine_status,access_class,detected_by,correlation_key
  ) values(
    p_case_id,p_source_message_id,'PAYMENT_PROOF','whatsapp-message:'||p_source_message_id::text,v_hash,
    'Payment evidence received — Finance verification pending','QUARANTINED','FINANCE_ONLY',v_detector,
    'payment-proof-evidence:'||v_key
  )
  on conflict(case_id,content_hash) do update set content_hash=excluded.content_hash
  returning * into v_restricted;

  insert into public.whatsapp_case_payment_proofs(
    case_id,restricted_evidence_id,claimed_amount,claimed_reference,receipt_status,received_at,correlation_key
  ) values(
    p_case_id,v_restricted.id,p_claimed_amount,nullif(btrim(coalesce(p_claimed_reference,'')),''),'RECEIVED',statement_timestamp(),'payment-proof:'||v_key
  ) returning * into v_proof;

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(p_case_id,'PAYMENT_PROOF_RECEIVED',case when v_detector='OPERATOR' then v_actor else null end,case when v_detector='OPERATOR' then 'OPERATOR' else 'SYSTEM' end,
    'payment-proof-event:'||v_key,jsonb_build_object('payment_proof_id',v_proof.id,'receipt_status','RECEIVED'),
    jsonb_build_object('detected_by',v_detector,'source_message_id',p_source_message_id,'finance_verification_pending',true));

  return jsonb_build_object('case_id',p_case_id,'payment_proof_id',v_proof.id,'receipt_status','RECEIVED','finance_verification_pending',true,'idempotent_replay',false);
end;
$$;

-- =================================================================================
-- Grants unchanged from the last effective version of this function
-- (CREATE OR REPLACE FUNCTION preserves existing ACLs, so this is a
-- functional no-op); restated explicitly per migration governance, which
-- requires every migration creating SECURITY DEFINER code to carry its own
-- REVOKE ALL / GRANT EXECUTE pair rather than relying on inherited grants.
-- =================================================================================

revoke all on function public.capture_whatsapp_payment_proof_evidence(uuid,uuid,text,numeric,text,text) from public,anon,authenticated,service_role;
grant execute on function public.capture_whatsapp_payment_proof_evidence(uuid,uuid,text,numeric,text,text) to authenticated,service_role;
