-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260818010400_whatsapp_clarification_answer_temporal_guard.sql (head 3b013b4); comment/whitespace-only delta consistent with pattern.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- A customer answer may only resolve a clarification if the cited inbound packet
-- message was captured after the clarification was asked. Historical packet
-- evidence cannot be retroactively treated as an answer to a later question.

create or replace function public.whatsapp_confirm_clarification_answer(
  p_clarification_id uuid,
  p_answer_source_message_id uuid,
  p_answer_text text,
  p_answer_payload jsonb default '{}'::jsonb,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_clarification public.whatsapp_case_clarifications%rowtype;
  v_case public.whatsapp_communication_cases%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
  v_message public.whatsapp_messages%rowtype;
  v_answer text := btrim(coalesce(p_answer_text,''));
  v_key text := btrim(coalesce(p_idempotency_key,''));
  v_next_due timestamptz;
  v_remaining integer;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WhatsApp triage permission required' using errcode='42501';
  end if;
  if length(v_answer) < 1 or length(v_answer) > 4000 then raise exception 'clarification answer required'; end if;
  if lower(v_answer) in ('yes','y','ok','okay','confirmed','haan','ha') then
    raise exception 'ambiguous clarification answer cannot resolve a field';
  end if;
  if p_answer_payload is null or jsonb_typeof(p_answer_payload) <> 'object' then
    raise exception 'clarification answer payload must be an object';
  end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_clarification
  from public.whatsapp_case_clarifications
  where id=p_clarification_id
  for update;
  if not found then raise exception 'clarification not found'; end if;

  select * into v_case
  from public.whatsapp_communication_cases
  where id=v_clarification.case_id
  for update;
  if not found then raise exception 'communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed case cannot accept clarification answer'; end if;

  if exists(
    select 1 from public.whatsapp_case_events
    where case_id=v_case.id and correlation_key='clarification-answer:'||v_key
  ) then
    return jsonb_build_object(
      'case_id',v_case.id,
      'clarification_id',v_clarification.id,
      'status',v_clarification.status,
      'idempotent_replay',true
    );
  end if;

  if v_clarification.status <> 'OPEN' then raise exception 'clarification is not open'; end if;

  select * into v_auth
  from public.whatsapp_case_recipient_authorizations
  where id=v_clarification.recipient_authorization_id and case_id=v_case.id;
  if not found or v_auth.revoked_at is not null then raise exception 'clarification recipient authority is no longer active'; end if;

  select * into v_message
  from public.whatsapp_messages
  where id=p_answer_source_message_id
    and packet_id=v_case.packet_id
    and lower(direction)='inbound'
    and created_at >= (v_clarification.asked_at at time zone 'UTC');
  if not found then
    raise exception 'answer source must be an inbound case message captured after the clarification was asked';
  end if;

  update public.whatsapp_case_clarifications
  set status='ANSWERED',
      answer_text=v_answer,
      answer_payload=p_answer_payload,
      answer_source_message_id=v_message.id,
      answered_by_identity_id=v_auth.identity_id,
      confirmed_by=v_actor,
      answered_at=statement_timestamp(),
      next_follow_up_at=null
  where id=v_clarification.id
  returning * into v_clarification;

  select count(*), min(due_at)
  into v_remaining,v_next_due
  from public.whatsapp_case_clarifications
  where case_id=v_case.id and status='OPEN';

  update public.whatsapp_communication_cases
  set status=case when v_remaining=0 then 'OPEN' else 'NEEDS_CLARIFICATION' end,
      next_action=case when v_remaining=0 then 'Review confirmed customer clarification answer'
                       else 'Resolve remaining customer clarifications' end,
      next_action_due_at=v_next_due,
      updated_at=statement_timestamp()
  where id=v_case.id
  returning * into v_case;

  insert into public.whatsapp_case_events(
    case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata
  ) values (
    v_case.id,'CUSTOMER_CLARIFICATION_ANSWER_CONFIRMED',v_actor,'OPERATOR',
    'clarification-answer:'||v_key,
    jsonb_build_object('clarification_id',v_clarification.id,'field_name',v_clarification.field_name,'status','ANSWERED'),
    jsonb_build_object('answer_source_message_id',v_message.id,'provider_message_id',v_message.provider_message_id,
      'answered_by_identity_id',v_auth.identity_id,'remaining_open_clarifications',v_remaining,
      'temporal_guard','captured_after_question')
  );

  return jsonb_build_object(
    'case_id',v_case.id,'clarification_id',v_clarification.id,'status',v_clarification.status,
    'remaining_open_clarifications',v_remaining,'idempotent_replay',false
  );
end;
$$;

revoke all on function public.whatsapp_confirm_clarification_answer(uuid,uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.whatsapp_confirm_clarification_answer(uuid,uuid,text,jsonb,text) to authenticated;
