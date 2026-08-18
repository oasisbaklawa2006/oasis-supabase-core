-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260818010800_whatsapp_payment_proof_governance.sql (head 3b013b4); comment/whitespace-only delta consistent with pattern.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- PAYMENT_ADVICE is evidence, never payment verification. Packet AI may automatically
-- quarantine/capture supported evidence as RECEIVED. Only an AAL2 Finance-authorised
-- human may mark the WhatsApp case proof VERIFIED or REJECTED, and that review does not
-- by itself mutate the canonical order/payment ledger.

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

  v_hash:=encode(digest(p_case_id::text||':'||p_source_message_id::text||':'||coalesce(v_message.provider_message_id,''),'sha256'),'hex');
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
revoke all on function public.capture_whatsapp_payment_proof_evidence(uuid,uuid,text,numeric,text,text) from public,anon,authenticated,service_role;
grant execute on function public.capture_whatsapp_payment_proof_evidence(uuid,uuid,text,numeric,text,text) to authenticated,service_role;


create or replace function public.materialize_whatsapp_payment_advice_from_ai_event()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_case public.whatsapp_communication_cases%rowtype;
  v_ai public.whatsapp_packet_ai_interpretations%rowtype;
  v_interpretation_id uuid;
  v_fact jsonb;
  v_provider text;
  v_message_id uuid;
  v_seen text[]:='{}'::text[];
begin
  if new.event_type<>'AI_CONCLUSION_READY' or new.actor_type<>'SYSTEM' or new.actor_id is not null then return new; end if;
  begin v_interpretation_id:=nullif(new.metadata->>'packet_ai_interpretation_id','')::uuid; exception when others then return new; end;
  if v_interpretation_id is null then return new; end if;
  select * into v_case from public.whatsapp_communication_cases where id=new.case_id;
  select * into v_ai from public.whatsapp_packet_ai_interpretations where id=v_interpretation_id and packet_id=v_case.packet_id;
  if not found or upper(coalesce(v_ai.interpretation#>>'{conclusion,intent}',''))<>'PAYMENT_ADVICE' then return new; end if;
  if jsonb_typeof(v_ai.interpretation#>'{conclusion,explicit_facts}')<>'array' then return new; end if;

  for v_fact in select value from jsonb_array_elements(v_ai.interpretation#>'{conclusion,explicit_facts}') loop
    if coalesce(v_fact->>'kind','')||' '||coalesce(v_fact->>'value','') !~* '(payment|utr|transaction|bank|receipt|proof|paid)' then continue; end if;
    v_provider:=nullif(btrim(coalesce(v_fact->>'provider_message_id','')),'');
    if v_provider is null or v_provider=any(v_seen) then continue; end if;
    select id into v_message_id from public.whatsapp_messages
    where packet_id=v_case.packet_id and direction='inbound' and provider_message_id=v_provider limit 1;
    if v_message_id is null then continue; end if;
    perform public.capture_whatsapp_payment_proof_evidence(
      v_case.id,v_message_id,'AI',null,null,'ai:'||v_interpretation_id::text||':'||v_provider
    );
    v_seen:=array_append(v_seen,v_provider);
  end loop;
  return new;
end;
$$;
revoke all on function public.materialize_whatsapp_payment_advice_from_ai_event() from public,anon,authenticated,service_role;

drop trigger if exists whatsapp_case_payment_advice_after_ai on public.whatsapp_case_events;
create trigger whatsapp_case_payment_advice_after_ai
after insert on public.whatsapp_case_events
for each row when (new.event_type='AI_CONCLUSION_READY' and new.actor_type='SYSTEM')
execute function public.materialize_whatsapp_payment_advice_from_ai_event();


create or replace function public.whatsapp_review_case_payment_proof(
  p_payment_proof_id uuid,
  p_decision text,
  p_verified_amount numeric,
  p_verified_reference text,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_decision text:=upper(btrim(coalesce(p_decision,'')));
  v_reference text:=btrim(coalesce(p_verified_reference,''));
  v_reason text:=btrim(coalesce(p_reason,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_proof public.whatsapp_case_payment_proofs%rowtype;
begin
  if v_actor is null then raise exception 'authentication required' using errcode='42501'; end if;
  perform public.assert_order_transition_role('finance_review');
  if not public.has_step_up_auth() then raise exception 'AAL2 required for payment-proof verification' using errcode='42501'; end if;
  if v_decision not in ('VERIFIED','REJECTED') then raise exception 'payment proof decision must be VERIFIED or REJECTED'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_proof from public.whatsapp_case_payment_proofs where id=p_payment_proof_id for update;
  if not found then raise exception 'payment proof not found'; end if;
  if exists(select 1 from public.whatsapp_case_events where case_id=v_proof.case_id and correlation_key='payment-proof-review:'||v_key) then
    return jsonb_build_object('case_id',v_proof.case_id,'payment_proof_id',v_proof.id,'receipt_status',v_proof.receipt_status,'idempotent_replay',true);
  end if;
  if v_proof.receipt_status in ('VERIFIED','REJECTED') then raise exception 'payment proof already has a final Finance decision'; end if;

  if v_decision='VERIFIED' then
    if p_verified_amount is null or p_verified_amount<=0 or length(v_reference)<3 then raise exception 'verified amount and Finance reference required'; end if;
    update public.whatsapp_case_payment_proofs set receipt_status='VERIFIED',verified_amount=p_verified_amount,
      verified_reference=v_reference,verified_by=v_actor,verified_at=statement_timestamp(),rejection_reason=null
    where id=v_proof.id returning * into v_proof;
  else
    if length(v_reason)<5 or length(v_reason)>1000 then raise exception 'rejection reason required'; end if;
    update public.whatsapp_case_payment_proofs set receipt_status='REJECTED',verified_amount=null,verified_reference=null,
      verified_by=v_actor,verified_at=statement_timestamp(),rejection_reason=v_reason
    where id=v_proof.id returning * into v_proof;
  end if;

  update public.whatsapp_case_restricted_evidence
  set quarantine_status='REVIEWED',reviewed_by=v_actor,reviewed_at=statement_timestamp(),release_reason=null
  where id=v_proof.restricted_evidence_id and quarantine_status='QUARANTINED';

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(v_proof.case_id,'PAYMENT_PROOF_'||v_decision,v_actor,'OPERATOR','payment-proof-review:'||v_key,
    jsonb_build_object('payment_proof_id',v_proof.id,'receipt_status',v_decision),
    jsonb_build_object('finance_review',true,'verified_amount',case when v_decision='VERIFIED' then v_proof.verified_amount else null end,
      'verified_reference',case when v_decision='VERIFIED' then v_proof.verified_reference else null end,'reason',case when v_decision='REJECTED' then v_reason else null end,
      'order_payment_mutated',false));

  return jsonb_build_object('case_id',v_proof.case_id,'payment_proof_id',v_proof.id,'receipt_status',v_proof.receipt_status,
    'order_payment_mutated',false,'idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_review_case_payment_proof(uuid,text,numeric,text,text,text) from public,anon,authenticated,service_role;
grant execute on function public.whatsapp_review_case_payment_proof(uuid,text,numeric,text,text,text) to authenticated;
