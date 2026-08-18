-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260818010200_whatsapp_case_lookup_and_clarification_answer.sql (head 3b013b4); full diff performed (highest relative delta in the set, 11.5%) -- comment/whitespace-only.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- Read-safe B2B lookup and human-confirmed clarification-answer closure for the
-- Decision Desk. Neither function creates commercial truth automatically.

create or replace function public.whatsapp_search_b2b_companies(
  p_query text,
  p_limit integer default 20
)
returns table(
  id uuid,
  business_name text,
  phone text,
  gst_number text,
  status text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_query text := btrim(coalesce(p_query, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 30));
begin
  if v_actor is null or not public.is_whatsapp_inbox_reader(v_actor) then
    raise exception 'WhatsApp inbox read permission required' using errcode = '42501';
  end if;
  if length(v_query) < 2 or length(v_query) > 100 then
    raise exception 'company search requires 2-100 characters';
  end if;

  return query
  select c.id, c.business_name, c.phone, c.gst_number, c.status
  from public.companies c
  where c.business_name ilike '%' || v_query || '%'
     or coalesce(c.phone, '') ilike '%' || v_query || '%'
     or coalesce(c.gst_number, '') ilike '%' || v_query || '%'
  order by
    case when lower(c.business_name) = lower(v_query) then 0
         when lower(c.business_name) like lower(v_query) || '%' then 1
         else 2 end,
    c.business_name,
    c.id
  limit v_limit;
end;
$$;

comment on function public.whatsapp_search_b2b_companies(text,integer) is
  'Minimal B2B company lookup for authorised WhatsApp inbox readers. Returns identity candidates only; selection is a separate human authority action.';
revoke all on function public.whatsapp_search_b2b_companies(text,integer) from public,anon;
grant execute on function public.whatsapp_search_b2b_companies(text,integer) to authenticated;


create or replace function public.whatsapp_get_case_draft_candidates(p_packet_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_result jsonb;
begin
  if v_actor is null or not public.is_whatsapp_inbox_reader(v_actor) then
    raise exception 'WhatsApp inbox read permission required' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc, x.id desc), '[]'::jsonb)
  into v_result
  from (
    select id,status,company_id,company_name,readiness_overall_score,
           readiness_dimensions,promoted_order_id,created_at,updated_at
    from public.sales_order_drafts
    where packet_id = p_packet_id
    order by created_at desc,id desc
    limit 20
  ) x;

  return v_result;
end;
$$;

comment on function public.whatsapp_get_case_draft_candidates(uuid) is
  'Read-only governed Sales Order Draft candidates for one WhatsApp packet; does not link or promote a draft.';
revoke all on function public.whatsapp_get_case_draft_candidates(uuid) from public,anon;
grant execute on function public.whatsapp_get_case_draft_candidates(uuid) to authenticated;


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
    and lower(direction)='inbound';
  if not found then raise exception 'answer source is not an inbound message in this case packet'; end if;

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
      'answered_by_identity_id',v_auth.identity_id,'remaining_open_clarifications',v_remaining)
  );

  return jsonb_build_object(
    'case_id',v_case.id,'clarification_id',v_clarification.id,'status',v_clarification.status,
    'remaining_open_clarifications',v_remaining,'idempotent_replay',false
  );
end;
$$;

comment on function public.whatsapp_confirm_clarification_answer(uuid,uuid,text,jsonb,text) is
  'Human confirmation that a specific inbound packet message answers a targeted clarification. Generic affirmation is rejected and no commercial field is auto-promoted.';
revoke all on function public.whatsapp_confirm_clarification_answer(uuid,uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.whatsapp_confirm_clarification_answer(uuid,uuid,text,jsonb,text) to authenticated;
