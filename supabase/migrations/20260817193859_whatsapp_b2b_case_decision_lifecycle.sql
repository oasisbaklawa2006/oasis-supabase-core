-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260818010000_whatsapp_b2b_case_decision_lifecycle.sql (head 3b013b4); full 55KB line-by-line diff performed in the prior reconciliation session -- every hunk is a COMMENT ON FUNCTION addition or whitespace-around-operators, zero logic/condition/constant differences.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- Complete the governed B2B WhatsApp communication-case lifecycle without creating
-- a parallel authority. Packet AI remains advisory. Every identity confirmation,
-- routing decision, clarification, outbound release, escalation, draft linkage and
-- closure below is attributable to an authenticated human. Provider transmission
-- continues to use the existing WA-5 outbox and WA-6 disclosure guard.

create or replace function public.whatsapp_case_potential_order_id(p_case_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_packet_id uuid;
  v_ids uuid[];
begin
  select packet_id into v_packet_id
  from public.whatsapp_communication_cases
  where id = p_case_id;

  if v_packet_id is null then
    return null;
  end if;

  select coalesce(array_agg(distinct evidence.potential_order_id), '{}'::uuid[])
  into v_ids
  from public.whatsapp_commercial_evidence evidence
  where evidence.packet_id = v_packet_id
    and evidence.potential_order_id is not null;

  if cardinality(v_ids) > 1 then
    raise exception 'multiple potential orders are linked to this communication case';
  end if;

  return case when cardinality(v_ids) = 1 then v_ids[1] else null end;
end;
$$;

comment on function public.whatsapp_case_potential_order_id(uuid) is
  'Internal fail-closed resolver for the single governed potential order, if any, represented by one WhatsApp communication case.';
revoke all on function public.whatsapp_case_potential_order_id(uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_case_potential_order_id(uuid) to service_role;


create or replace function public.whatsapp_confirm_case_identity(
  p_case_id uuid,
  p_company_id uuid,
  p_verification_method text,
  p_disclosure_scope text[] default '{}'::text[],
  p_may_receive_clarification boolean default true,
  p_may_confirm_commercial_scope boolean default false,
  p_valid_until timestamptz default null,
  p_identity_evidence jsonb default '{}'::jsonb,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_company public.companies%rowtype;
  v_sender_identity public.whatsapp_case_identities%rowtype;
  v_customer_identity public.whatsapp_case_identities%rowtype;
  v_authorization public.whatsapp_case_recipient_authorizations%rowtype;
  v_method text := upper(btrim(coalesce(p_verification_method, '')));
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_scope text[];
  v_allowed_scope constant text[] := array[
    'customer_pricing','moq_carton','payment_terms','delivery_address',
    'previous_orders','account_balance','draft_order','sales_order'
  ]::text[];
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WhatsApp triage permission required' using errcode = '42501';
  end if;
  if v_method not in ('CRM_MATCH','GST_MATCH','CALLBACK','OPERATOR_VERIFIED','CUSTOMER_NOMINATED') then
    raise exception 'unsupported identity verification method';
  end if;
  if v_key = '' or length(v_key) > 160 then raise exception 'idempotency key required'; end if;
  if p_identity_evidence is null or jsonb_typeof(p_identity_evidence) <> 'object' or p_identity_evidence = '{}'::jsonb then
    raise exception 'identity evidence required';
  end if;

  select coalesce(array_agg(distinct lower(btrim(scope)) order by lower(btrim(scope))), '{}'::text[])
  into v_scope
  from unnest(coalesce(p_disclosure_scope, '{}'::text[])) scope
  where btrim(scope) <> '';

  if exists(select 1 from unnest(v_scope) scope where not scope = any(v_allowed_scope)) then
    raise exception 'unsupported commercial disclosure scope';
  end if;

  if (cardinality(v_scope) > 0 or p_may_confirm_commercial_scope)
     and not public.has_whatsapp_permission('wa.disclosure.authorize') then
    raise exception 'commercial disclosure authorization permission required' using errcode = '42501';
  end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed case identity cannot be changed'; end if;

  if exists(select 1 from public.whatsapp_case_events where case_id=p_case_id and correlation_key='identity-confirm:'||v_key) then
    select * into v_authorization
    from public.whatsapp_case_recipient_authorizations
    where case_id=p_case_id and correlation_key='identity-confirm:'||v_key
    order by created_at desc limit 1;
    return jsonb_build_object(
      'case_id', p_case_id,
      'company_id', v_case.company_id,
      'recipient_authorization_id', v_authorization.id,
      'idempotent_replay', true
    );
  end if;

  select * into v_packet from public.whatsapp_message_packets where id=v_case.packet_id;
  if not found then raise exception 'case packet not found'; end if;
  select * into v_contact from public.whatsapp_contacts where id=v_packet.contact_id;
  if not found then raise exception 'case contact not found'; end if;
  select * into v_company from public.companies where id=p_company_id;
  if not found then raise exception 'B2B company not found'; end if;

  insert into public.whatsapp_case_identities(
    case_id,identity_role,party_type,party_id,display_label,phone_e164,
    resolution_status,confidence,resolved_by,resolved_at,evidence
  ) values (
    p_case_id,'SUBMITTING_SENDER','CONTACT',v_contact.id,
    coalesce(nullif(v_contact.customer_name,''),nullif(v_contact.company_name,''),v_contact.phone_number),
    v_contact.phone_number,'CONFIRMED',1.0,v_actor,statement_timestamp(),
    jsonb_build_array(p_identity_evidence || jsonb_build_object('verification_method',v_method,'contact_id',v_contact.id))
  )
  on conflict(case_id,identity_role) do update
  set party_type=excluded.party_type,
      party_id=excluded.party_id,
      display_label=excluded.display_label,
      phone_e164=excluded.phone_e164,
      resolution_status='CONFIRMED',
      confidence=1.0,
      resolved_by=v_actor,
      resolved_at=statement_timestamp(),
      evidence=public.whatsapp_case_identities.evidence || excluded.evidence
  returning * into v_sender_identity;

  insert into public.whatsapp_case_identities(
    case_id,identity_role,party_type,party_id,display_label,phone_e164,
    resolution_status,confidence,resolved_by,resolved_at,evidence
  ) values (
    p_case_id,'COMMERCIAL_CUSTOMER','COMPANY',v_company.id,v_company.business_name,v_company.phone,
    'CONFIRMED',1.0,v_actor,statement_timestamp(),
    jsonb_build_array(p_identity_evidence || jsonb_build_object('verification_method',v_method,'company_id',v_company.id))
  )
  on conflict(case_id,identity_role) do update
  set party_type=excluded.party_type,
      party_id=excluded.party_id,
      display_label=excluded.display_label,
      phone_e164=excluded.phone_e164,
      resolution_status='CONFIRMED',
      confidence=1.0,
      resolved_by=v_actor,
      resolved_at=statement_timestamp(),
      evidence=public.whatsapp_case_identities.evidence || excluded.evidence
  returning * into v_customer_identity;

  insert into public.whatsapp_case_recipient_authorizations(
    case_id,identity_id,disclosure_scope,may_receive_clarification,
    may_confirm_commercial_scope,verification_method,verified_by,verified_at,correlation_key
  ) values (
    p_case_id,v_sender_identity.id,v_scope,coalesce(p_may_receive_clarification,true),
    coalesce(p_may_confirm_commercial_scope,false),v_method,v_actor,statement_timestamp(),
    'identity-confirm:'||v_key
  ) returning * into v_authorization;

  update public.whatsapp_communication_cases
  set company_id=v_company.id,
      status=case when status='NEEDS_IDENTITY' then 'OPEN' else status end,
      updated_at=statement_timestamp()
  where id=p_case_id returning * into v_case;

  if cardinality(v_scope) > 0 then
    if p_valid_until is null then raise exception 'commercial disclosure authorization expiry required'; end if;
    perform public.authorize_whatsapp_commercial_disclosure(
      v_contact.id,
      v_company.id,
      v_scope,
      p_identity_evidence || jsonb_build_object('case_id',p_case_id,'recipient_authorization_id',v_authorization.id),
      p_valid_until
    );
  end if;

  insert into public.whatsapp_case_events(
    case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata
  ) values (
    p_case_id,'CASE_IDENTITY_CONFIRMED',v_actor,'OPERATOR','identity-confirm:'||v_key,
    jsonb_build_object('company_id',v_company.id,'sender_identity_id',v_sender_identity.id,'customer_identity_id',v_customer_identity.id),
    jsonb_build_object('verification_method',v_method,'recipient_authorization_id',v_authorization.id,
      'disclosure_scope',to_jsonb(v_scope),'may_receive_clarification',p_may_receive_clarification,
      'may_confirm_commercial_scope',p_may_confirm_commercial_scope)
  );

  return jsonb_build_object(
    'case_id',p_case_id,'company_id',v_company.id,
    'sender_identity_id',v_sender_identity.id,'customer_identity_id',v_customer_identity.id,
    'recipient_authorization_id',v_authorization.id,'idempotent_replay',false
  );
end;
$$;

comment on function public.whatsapp_confirm_case_identity(uuid,uuid,text,text[],boolean,boolean,timestamptz,jsonb,text) is
  'Human-authorised B2B customer/sender confirmation for one governed WhatsApp case. Commercial disclosure scope additionally requires WA-6 step-up authority.';
revoke all on function public.whatsapp_confirm_case_identity(uuid,uuid,text,text[],boolean,boolean,timestamptz,jsonb,text) from public,anon,authenticated;
grant execute on function public.whatsapp_confirm_case_identity(uuid,uuid,text,text[],boolean,boolean,timestamptz,jsonb,text) to authenticated;


create or replace function public.whatsapp_record_ai_case_decision(
  p_case_id uuid,
  p_decision text,
  p_reason text,
  p_case_type text default null,
  p_next_action text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_decision text := upper(btrim(coalesce(p_decision,'')));
  v_reason text := btrim(coalesce(p_reason,''));
  v_type text := upper(btrim(coalesce(p_case_type,'')));
  v_action text := nullif(btrim(coalesce(p_next_action,'')),'');
  v_key text := btrim(coalesce(p_idempotency_key,''));
  v_event_type text;
  v_allowed_types constant text[] := array[
    'UNCLASSIFIED','ORDER','ORDER_CHANGE','CANCELLATION','ENQUIRY','COMPLAINT',
    'PAYMENT_ADVICE','ACCOUNT_QUERY','DISPATCH','SPECIFICATION'
  ]::text[];
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WhatsApp triage permission required' using errcode='42501';
  end if;
  if v_decision not in ('ACCEPT','MODIFY','REJECT') then raise exception 'invalid AI case decision'; end if;
  if length(v_reason) < 5 or length(v_reason) > 1000 then raise exception 'decision reason required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;
  if v_type<>'' and not v_type=any(v_allowed_types) then raise exception 'unsupported communication case type'; end if;
  if v_decision='MODIFY' and v_type='' and v_action is null then raise exception 'modified AI decision must change case type or next action'; end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed case cannot receive AI decision'; end if;

  v_event_type := case v_decision
    when 'ACCEPT' then 'AI_CONCLUSION_ACCEPTED'
    when 'MODIFY' then 'AI_CONCLUSION_MODIFIED'
    else 'AI_CONCLUSION_REJECTED'
  end;

  if exists(select 1 from public.whatsapp_case_events where case_id=p_case_id and correlation_key='ai-decision:'||v_key) then
    return jsonb_build_object('case_id',p_case_id,'decision',v_decision,'idempotent_replay',true);
  end if;

  if v_decision='MODIFY' then
    update public.whatsapp_communication_cases
    set case_type=case when v_type='' then case_type else v_type end,
        next_action=coalesce(v_action,next_action),
        rule_version='packet-ai-b2b-v1+human-modified',
        updated_at=statement_timestamp()
    where id=p_case_id returning * into v_case;
  elsif v_decision='REJECT' and v_case.accountability_status='UNASSIGNED' then
    update public.whatsapp_communication_cases
    set case_type='UNCLASSIFIED',
        next_action=coalesce(v_action,next_action),
        rule_version='packet-ai-b2b-v1+human-rejected',
        updated_at=statement_timestamp()
    where id=p_case_id returning * into v_case;
  end if;

  insert into public.whatsapp_case_events(
    case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata
  ) values (
    p_case_id,v_event_type,v_actor,'OPERATOR','ai-decision:'||v_key,
    jsonb_build_object('decision',v_decision,'case_type',v_case.case_type,'next_action',v_case.next_action),
    jsonb_build_object('reason',v_reason,'human_authority',true)
  );

  return jsonb_build_object('case_id',p_case_id,'decision',v_decision,'case_type',v_case.case_type,
    'next_action',v_case.next_action,'idempotent_replay',false);
end;
$$;

comment on function public.whatsapp_record_ai_case_decision(uuid,text,text,text,text,text) is
  'Records an attributable accept/modify/reject decision over advisory packet AI. It never creates commercial truth.';
revoke all on function public.whatsapp_record_ai_case_decision(uuid,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.whatsapp_record_ai_case_decision(uuid,text,text,text,text,text) to authenticated;


create or replace function public.whatsapp_ask_customer(
  p_case_id uuid,
  p_recipient_authorization_id uuid,
  p_field_name text,
  p_question text,
  p_due_at timestamptz,
  p_disclosure_scope text[] default '{}'::text[],
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
  v_clarification public.whatsapp_case_clarifications%rowtype;
  v_decision public.whatsapp_case_outbound_decisions%rowtype;
  v_reply public.whatsapp_operator_reply_outbox%rowtype;
  v_field text := upper(btrim(coalesce(p_field_name,'')));
  v_question text := btrim(coalesce(p_question,''));
  v_key text := btrim(coalesce(p_idempotency_key,''));
  v_scope text[];
  v_potential_order_id uuid;
begin
  if v_actor is null
     or not public.has_whatsapp_permission('wa.intake.triage')
     or not public.has_whatsapp_permission('wa.reply.send') then
    raise exception 'WhatsApp triage and reply permissions required' using errcode='42501';
  end if;
  if v_field='' or v_field='UNSPECIFIED' or length(v_field)>120 then raise exception 'target clarification field required'; end if;
  if length(v_question)<8 or length(v_question)>4000 then raise exception 'targeted clarification question required'; end if;
  if lower(v_question) in ('please clarify','kindly clarify','confirm','please confirm') then raise exception 'generic clarification is not allowed'; end if;
  if p_due_at is null or p_due_at<=statement_timestamp() then raise exception 'future clarification due time required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed case cannot ask customer'; end if;

  if exists(select 1 from public.whatsapp_case_events where case_id=p_case_id and correlation_key='ask-customer:'||v_key) then
    select * into v_clarification from public.whatsapp_case_clarifications
    where case_id=p_case_id and correlation_key='ask-customer:'||v_key;
    return jsonb_build_object('case_id',p_case_id,'clarification_id',v_clarification.id,'idempotent_replay',true);
  end if;

  select * into v_auth from public.whatsapp_case_recipient_authorizations
  where id=p_recipient_authorization_id and case_id=p_case_id for share;
  if not found or v_auth.revoked_at is not null or not v_auth.may_receive_clarification then
    raise exception 'recipient is not authorised for clarification';
  end if;

  select coalesce(array_agg(distinct scope order by scope),'{}'::text[])
  into v_scope
  from unnest(coalesce(p_disclosure_scope,'{}'::text[]) || coalesce(public.wa6_infer_commercial_disclosure(v_question),'{}'::text[])) scope
  where btrim(scope)<>'';
  if not v_scope <@ v_auth.disclosure_scope then raise exception 'clarification disclosure exceeds recipient authority'; end if;

  select * into v_packet from public.whatsapp_message_packets where id=v_case.packet_id;
  select * into v_contact from public.whatsapp_contacts where id=v_packet.contact_id;
  if v_packet.id is null or v_contact.id is null then raise exception 'case packet/contact boundary missing'; end if;

  v_potential_order_id := public.whatsapp_case_potential_order_id(p_case_id);
  if cardinality(v_scope)>0 and v_potential_order_id is null then
    raise exception 'commercial clarification requires one governed potential order';
  end if;

  insert into public.whatsapp_case_clarifications(
    case_id,field_name,unresolved_value,question,recipient_authorization_id,status,
    due_at,next_follow_up_at,asked_by,correlation_key
  ) values (
    p_case_id,v_field,null,v_question,p_recipient_authorization_id,'OPEN',
    p_due_at,p_due_at,v_actor,'ask-customer:'||v_key
  ) returning * into v_clarification;

  insert into public.whatsapp_case_outbound_decisions(
    case_id,recipient_authorization_id,message_purpose,disclosure_scope,message_body,
    related_clarification_id,status,idempotency_key,rule_version,created_by
  ) values (
    p_case_id,p_recipient_authorization_id,'CLARIFICATION',v_scope,v_question,
    v_clarification.id,'DRAFT','ask-customer:'||v_key,'b2b-case-decision-v1',v_actor
  ) returning * into v_decision;

  insert into public.whatsapp_case_reply_validations(
    outbound_decision_id,validation_version,factual_consistency_status,recipient_authority_status,
    disclosure_status,ambiguity_status,commercial_commitment_status,validator_type,
    validator_version,findings,validated_by,correlation_key
  ) values (
    v_decision.id,1,'PASS','PASS','PASS','PASS','NONE','OPERATOR',
    'b2b-case-decision-v1','[]'::jsonb,v_actor,'ask-customer:'||v_key||':validation'
  );

  update public.whatsapp_case_outbound_decisions
  set status='RELEASED',validated_at=statement_timestamp(),released_by=v_actor,released_at=statement_timestamp()
  where id=v_decision.id returning * into v_decision;

  v_reply := public.enqueue_whatsapp_operator_reply(
    v_packet.id,v_contact.id,'+'||regexp_replace(v_contact.phone_number,'\D','','g'),v_question,
    'case:'||v_decision.id::text,v_potential_order_id,null,'TEXT',null,null,null,v_scope
  );

  update public.whatsapp_case_clarifications
  set source_outbound_message_id=v_reply.id
  where id=v_clarification.id;

  update public.whatsapp_communication_cases
  set status='AWAITING_CUSTOMER',next_action='Await targeted customer clarification: '||v_field,
      next_action_due_at=p_due_at,updated_at=statement_timestamp()
  where id=p_case_id;

  insert into public.whatsapp_case_events(
    case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata
  ) values (
    p_case_id,'CUSTOMER_CLARIFICATION_RELEASED',v_actor,'OPERATOR','ask-customer:'||v_key,
    jsonb_build_object('status','AWAITING_CUSTOMER','field_name',v_field,'due_at',p_due_at),
    jsonb_build_object('clarification_id',v_clarification.id,'outbound_decision_id',v_decision.id,
      'wa5_reply_id',v_reply.id,'disclosure_scope',to_jsonb(v_scope))
  );

  return jsonb_build_object('case_id',p_case_id,'clarification_id',v_clarification.id,
    'outbound_decision_id',v_decision.id,'reply_id',v_reply.id,'reply_status',v_reply.status,
    'idempotent_replay',false);
end;
$$;

comment on function public.whatsapp_ask_customer(uuid,uuid,text,text,timestamptz,text[],text) is
  'Creates a targeted formal clarification, validates/releases the outbound decision, and enqueues it through WA-5 under recipient and WA-6 disclosure authority.';
revoke all on function public.whatsapp_ask_customer(uuid,uuid,text,text,timestamptz,text[],text) from public,anon,authenticated;
grant execute on function public.whatsapp_ask_customer(uuid,uuid,text,text,timestamptz,text[],text) to authenticated;


create or replace function public.whatsapp_release_case_reply(
  p_case_id uuid,
  p_recipient_authorization_id uuid,
  p_message_purpose text,
  p_message_body text,
  p_disclosure_scope text[] default '{}'::text[],
  p_related_milestone_event_id uuid default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
  v_decision public.whatsapp_case_outbound_decisions%rowtype;
  v_reply public.whatsapp_operator_reply_outbox%rowtype;
  v_purpose text := upper(btrim(coalesce(p_message_purpose,'')));
  v_body text := btrim(coalesce(p_message_body,''));
  v_key text := btrim(coalesce(p_idempotency_key,''));
  v_scope text[];
  v_potential_order_id uuid;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.reply.send') then
    raise exception 'WhatsApp reply permission required' using errcode='42501';
  end if;
  if v_purpose not in ('RECEIPT_ACKNOWLEDGEMENT','OPERATIONAL_MILESTONE','CASE_UPDATE','CASE_CLOSURE') then
    raise exception 'unsupported case reply purpose';
  end if;
  if length(v_body)<1 or length(v_body)>4000 then raise exception 'reply body required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;
  if (v_purpose='OPERATIONAL_MILESTONE') <> (p_related_milestone_event_id is not null) then
    raise exception 'operational milestone reply requires exactly one related milestone';
  end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') and v_purpose<>'CASE_CLOSURE' then raise exception 'closed case cannot send update'; end if;

  if exists(select 1 from public.whatsapp_case_events where case_id=p_case_id and correlation_key='case-reply:'||v_key) then
    select * into v_decision from public.whatsapp_case_outbound_decisions
    where case_id=p_case_id and idempotency_key='case-reply:'||v_key;
    select * into v_reply from public.whatsapp_operator_reply_outbox
    where packet_id=v_case.packet_id and idempotency_key='case:'||v_decision.id::text;
    return jsonb_build_object('case_id',p_case_id,'outbound_decision_id',v_decision.id,'reply_id',v_reply.id,
      'reply_status',v_reply.status,'idempotent_replay',true);
  end if;

  select * into v_auth from public.whatsapp_case_recipient_authorizations
  where id=p_recipient_authorization_id and case_id=p_case_id for share;
  if not found or v_auth.revoked_at is not null then raise exception 'active recipient authorization required'; end if;

  select coalesce(array_agg(distinct scope order by scope),'{}'::text[])
  into v_scope
  from unnest(coalesce(p_disclosure_scope,'{}'::text[]) || coalesce(public.wa6_infer_commercial_disclosure(v_body),'{}'::text[])) scope
  where btrim(scope)<>'';
  if not v_scope <@ v_auth.disclosure_scope then raise exception 'reply disclosure exceeds recipient authority'; end if;

  if p_related_milestone_event_id is not null and not exists(
    select 1 from public.whatsapp_case_milestone_events m
    where m.id=p_related_milestone_event_id and m.case_id=p_case_id
  ) then raise exception 'milestone belongs to another case'; end if;

  select * into v_packet from public.whatsapp_message_packets where id=v_case.packet_id;
  select * into v_contact from public.whatsapp_contacts where id=v_packet.contact_id;
  if v_packet.id is null or v_contact.id is null then raise exception 'case packet/contact boundary missing'; end if;

  v_potential_order_id := public.whatsapp_case_potential_order_id(p_case_id);
  if cardinality(v_scope)>0 and v_potential_order_id is null then
    raise exception 'commercial reply requires one governed potential order';
  end if;

  insert into public.whatsapp_case_outbound_decisions(
    case_id,recipient_authorization_id,message_purpose,disclosure_scope,message_body,
    related_milestone_event_id,status,idempotency_key,rule_version,created_by
  ) values (
    p_case_id,p_recipient_authorization_id,v_purpose,v_scope,v_body,p_related_milestone_event_id,
    'DRAFT','case-reply:'||v_key,'b2b-case-decision-v1',v_actor
  ) returning * into v_decision;

  insert into public.whatsapp_case_reply_validations(
    outbound_decision_id,validation_version,factual_consistency_status,recipient_authority_status,
    disclosure_status,ambiguity_status,commercial_commitment_status,validator_type,
    validator_version,findings,validated_by,correlation_key
  ) values (
    v_decision.id,1,'PASS','PASS','PASS','PASS',
    case when cardinality(v_scope)=0 then 'NONE' else 'AUTHORISED' end,
    'OPERATOR','b2b-case-decision-v1','[]'::jsonb,v_actor,'case-reply:'||v_key||':validation'
  );

  update public.whatsapp_case_outbound_decisions
  set status='RELEASED',validated_at=statement_timestamp(),released_by=v_actor,released_at=statement_timestamp()
  where id=v_decision.id returning * into v_decision;

  v_reply := public.enqueue_whatsapp_operator_reply(
    v_packet.id,v_contact.id,'+'||regexp_replace(v_contact.phone_number,'\D','','g'),v_body,
    'case:'||v_decision.id::text,v_potential_order_id,null,'TEXT',null,null,null,v_scope
  );

  insert into public.whatsapp_case_events(
    case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata
  ) values (
    p_case_id,'CASE_REPLY_RELEASED',v_actor,'OPERATOR','case-reply:'||v_key,
    jsonb_build_object('message_purpose',v_purpose,'reply_status',v_reply.status),
    jsonb_build_object('outbound_decision_id',v_decision.id,'wa5_reply_id',v_reply.id,
      'disclosure_scope',to_jsonb(v_scope))
  );

  return jsonb_build_object('case_id',p_case_id,'outbound_decision_id',v_decision.id,
    'reply_id',v_reply.id,'reply_status',v_reply.status,'idempotent_replay',false);
end;
$$;

comment on function public.whatsapp_release_case_reply(uuid,uuid,text,text,text[],uuid,text) is
  'Human release boundary for governed B2B case updates. Reuses recipient authority, outbound validations, WA-6 disclosure hardening and the existing WA-5 outbox.';
revoke all on function public.whatsapp_release_case_reply(uuid,uuid,text,text,text[],uuid,text) from public,anon,authenticated;
grant execute on function public.whatsapp_release_case_reply(uuid,uuid,text,text,text[],uuid,text) to authenticated;


create or replace function public.whatsapp_complete_case_task(
  p_task_id uuid,
  p_response_payload jsonb,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_task public.whatsapp_case_department_tasks%rowtype;
  v_key text:=btrim(coalesce(p_idempotency_key,''));
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then raise exception 'WhatsApp triage permission required' using errcode='42501'; end if;
  if p_response_payload is null or jsonb_typeof(p_response_payload)<>'object' or p_response_payload='{}'::jsonb then raise exception 'task response payload required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;
  select * into v_task from public.whatsapp_case_department_tasks where id=p_task_id for update;
  if not found then raise exception 'case task not found'; end if;
  if exists(select 1 from public.whatsapp_case_events where case_id=v_task.case_id and correlation_key='task-complete:'||v_key) then
    return jsonb_build_object('task_id',v_task.id,'case_id',v_task.case_id,'status',v_task.status,'idempotent_replay',true);
  end if;
  if v_task.status='CANCELLED' then raise exception 'cancelled case task cannot be completed'; end if;
  if v_task.status<>'COMPLETED' then
    update public.whatsapp_case_department_tasks
    set status='COMPLETED',response_payload=p_response_payload,completed_by=v_actor,completed_at=statement_timestamp(),updated_at=statement_timestamp()
    where id=v_task.id returning * into v_task;
  end if;
  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(v_task.case_id,'DEPARTMENT_TASK_COMPLETED',v_actor,'OPERATOR','task-complete:'||v_key,
    jsonb_build_object('task_id',v_task.id,'department',v_task.department,'status','COMPLETED'),p_response_payload);
  return jsonb_build_object('task_id',v_task.id,'case_id',v_task.case_id,'status',v_task.status,'idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_complete_case_task(uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.whatsapp_complete_case_task(uuid,jsonb,text) to authenticated;


create or replace function public.whatsapp_escalate_case(
  p_case_id uuid,
  p_escalation_level integer,
  p_reason text,
  p_escalated_to_team text,
  p_due_at timestamptz,
  p_department_task_id uuid default null,
  p_escalated_to_user_id uuid default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_escalation public.whatsapp_case_escalations%rowtype;
  v_team text:=upper(btrim(coalesce(p_escalated_to_team,'')));
  v_reason text:=btrim(coalesce(p_reason,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.assign') then raise exception 'WhatsApp assignment permission required' using errcode='42501'; end if;
  if p_escalation_level not between 1 and 5 then raise exception 'escalation level must be 1-5'; end if;
  if length(v_reason)<5 or length(v_reason)>1000 then raise exception 'escalation reason required'; end if;
  if not public.whatsapp_b2b_response_team_allowed(v_team) then raise exception 'unsupported escalation team'; end if;
  if p_due_at is null or p_due_at<=statement_timestamp() then raise exception 'future escalation due time required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed case cannot be escalated'; end if;
  if p_department_task_id is not null and not exists(select 1 from public.whatsapp_case_department_tasks t where t.id=p_department_task_id and t.case_id=p_case_id) then
    raise exception 'department task belongs to another case';
  end if;

  select * into v_escalation from public.whatsapp_case_escalations where case_id=p_case_id and correlation_key='case-escalate:'||v_key;
  if found then return jsonb_build_object('case_id',p_case_id,'escalation_id',v_escalation.id,'idempotent_replay',true); end if;

  insert into public.whatsapp_case_escalations(case_id,department_task_id,escalation_level,reason,escalated_to_team,escalated_to_user_id,due_at,correlation_key)
  values(p_case_id,p_department_task_id,p_escalation_level,v_reason,v_team,p_escalated_to_user_id,p_due_at,'case-escalate:'||v_key)
  returning * into v_escalation;

  update public.whatsapp_communication_cases
  set accountability_status='ESCALATED',last_escalated_at=statement_timestamp(),
      next_action='Escalated: '||v_reason,next_action_due_at=p_due_at,updated_at=statement_timestamp()
  where id=p_case_id;

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(p_case_id,'CASE_ESCALATED',v_actor,'OPERATOR','case-escalate:'||v_key,
    jsonb_build_object('level',p_escalation_level,'team',v_team,'due_at',p_due_at),
    jsonb_build_object('escalation_id',v_escalation.id,'reason',v_reason,'department_task_id',p_department_task_id));

  return jsonb_build_object('case_id',p_case_id,'escalation_id',v_escalation.id,'idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_escalate_case(uuid,integer,text,text,timestamptz,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.whatsapp_escalate_case(uuid,integer,text,text,timestamptz,uuid,uuid,text) to authenticated;


create or replace function public.whatsapp_resolve_case_escalation(
  p_escalation_id uuid,
  p_resolution text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_item public.whatsapp_case_escalations%rowtype;
  v_resolution text:=btrim(coalesce(p_resolution,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.assign') then raise exception 'WhatsApp assignment permission required' using errcode='42501'; end if;
  if length(v_resolution)<5 or length(v_resolution)>1000 then raise exception 'escalation resolution required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;
  select * into v_item from public.whatsapp_case_escalations where id=p_escalation_id for update;
  if not found then raise exception 'case escalation not found'; end if;
  if exists(select 1 from public.whatsapp_case_events where case_id=v_item.case_id and correlation_key='escalation-resolve:'||v_key) then
    return jsonb_build_object('case_id',v_item.case_id,'escalation_id',v_item.id,'idempotent_replay',true);
  end if;
  if v_item.resolved_at is null then
    update public.whatsapp_case_escalations set resolved_by=v_actor,resolved_at=statement_timestamp(),resolution=v_resolution where id=v_item.id returning * into v_item;
  end if;
  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(v_item.case_id,'CASE_ESCALATION_RESOLVED',v_actor,'OPERATOR','escalation-resolve:'||v_key,
    jsonb_build_object('escalation_id',v_item.id,'resolved',true),jsonb_build_object('resolution',v_resolution));
  return jsonb_build_object('case_id',v_item.case_id,'escalation_id',v_item.id,'idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_resolve_case_escalation(uuid,text,text) from public,anon,authenticated;
grant execute on function public.whatsapp_resolve_case_escalation(uuid,text,text) to authenticated;


create or replace function public.whatsapp_link_case_sales_order_draft(
  p_case_id uuid,
  p_sales_order_draft_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_draft public.sales_order_drafts%rowtype;
  v_key text:=btrim(coalesce(p_idempotency_key,''));
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.draft.manage') then raise exception 'WhatsApp draft management permission required' using errcode='42501'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;
  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed case cannot link a draft'; end if;
  select * into v_draft from public.sales_order_drafts where id=p_sales_order_draft_id;
  if not found then raise exception 'Sales Order Draft not found'; end if;
  if v_draft.packet_id<>v_case.packet_id then raise exception 'Sales Order Draft belongs to another WhatsApp packet'; end if;
  if v_case.company_id is not null and v_draft.company_id is not null and v_case.company_id<>v_draft.company_id then raise exception 'Sales Order Draft company does not match confirmed case customer'; end if;
  if exists(select 1 from public.whatsapp_case_events where case_id=p_case_id and correlation_key='draft-link:'||v_key) then
    return jsonb_build_object('case_id',p_case_id,'sales_order_draft_id',v_case.sales_order_draft_id,'idempotent_replay',true);
  end if;
  update public.whatsapp_communication_cases
  set sales_order_draft_id=v_draft.id,status='DRAFTED',next_action='Review governed Sales Order Draft',updated_at=statement_timestamp()
  where id=p_case_id returning * into v_case;
  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(p_case_id,'SALES_ORDER_DRAFT_LINKED',v_actor,'OPERATOR','draft-link:'||v_key,
    jsonb_build_object('sales_order_draft_id',v_draft.id,'status','DRAFTED'),
    jsonb_build_object('draft_status',v_draft.status,'promotion_not_implied',true));
  return jsonb_build_object('case_id',p_case_id,'sales_order_draft_id',v_draft.id,'case_status',v_case.status,'idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_link_case_sales_order_draft(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.whatsapp_link_case_sales_order_draft(uuid,uuid,text) to authenticated;


create or replace function public.whatsapp_record_case_milestone(
  p_case_id uuid,
  p_milestone_type text,
  p_customer_relevance text,
  p_facts jsonb,
  p_source_event_key text,
  p_business_object_type text default null,
  p_business_object_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_role text:=coalesce(auth.jwt()->>'role','');
  v_source text;
  v_type text:=upper(btrim(coalesce(p_milestone_type,'')));
  v_relevance text:=upper(btrim(coalesce(p_customer_relevance,'')));
  v_key text:=btrim(coalesce(p_source_event_key,''));
  v_event public.whatsapp_case_milestone_events%rowtype;
begin
  if v_role='service_role' then v_source:='SYSTEM';
  elsif v_actor is not null and public.has_whatsapp_permission('wa.intake.triage') then v_source:='OPERATOR';
  else raise exception 'trusted system or WhatsApp triage permission required' using errcode='42501';
  end if;
  if v_type not in ('REQUEST_RECEIVED','CLARIFICATION_REQUIRED','DRAFT_PREPARED','CUSTOMER_CONFIRMED','PAYMENT_PROOF_RECEIVED','PAYMENT_VERIFIED','PRODUCTION_STARTED','READY_FOR_DISPATCH','DISPATCHED','DELIVERED','EXCEPTION','CANCELLED','CLOSED') then raise exception 'unsupported case milestone'; end if;
  if v_relevance not in ('SILENT','OPTIONAL','REQUIRED') then raise exception 'invalid customer relevance'; end if;
  if p_facts is null or jsonb_typeof(p_facts)<>'object' then raise exception 'milestone facts must be an object'; end if;
  if v_key='' or length(v_key)>200 then raise exception 'source event key required'; end if;
  if not exists(select 1 from public.whatsapp_communication_cases where id=p_case_id) then raise exception 'WhatsApp communication case not found'; end if;
  insert into public.whatsapp_case_milestone_events(case_id,milestone_type,business_object_type,business_object_id,occurred_at,customer_relevance,source,source_event_key,facts)
  values(p_case_id,v_type,nullif(btrim(coalesce(p_business_object_type,'')),''),p_business_object_id,statement_timestamp(),v_relevance,v_source,v_key,p_facts)
  on conflict(case_id,source_event_key) do nothing;
  select * into v_event from public.whatsapp_case_milestone_events where case_id=p_case_id and source_event_key=v_key;
  if v_actor is not null then
    insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
    values(p_case_id,'CASE_MILESTONE_RECORDED',v_actor,'OPERATOR','milestone:'||v_key,
      jsonb_build_object('milestone_type',v_type,'customer_relevance',v_relevance),p_facts)
    on conflict(case_id,correlation_key) do nothing;
  end if;
  return jsonb_build_object('case_id',p_case_id,'milestone_event_id',v_event.id,'milestone_type',v_event.milestone_type,'customer_relevance',v_event.customer_relevance);
end;
$$;
revoke all on function public.whatsapp_record_case_milestone(uuid,text,text,jsonb,text,text,uuid) from public,anon,authenticated;
grant execute on function public.whatsapp_record_case_milestone(uuid,text,text,jsonb,text,text,uuid) to authenticated,service_role;


create or replace function public.whatsapp_close_case(
  p_case_id uuid,
  p_closure_type text,
  p_resolution_summary text,
  p_unresolved_items jsonb default '[]'::jsonb,
  p_customer_notified boolean default false,
  p_closure_outbound_decision_id uuid default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_closure public.whatsapp_case_closures%rowtype;
  v_type text:=upper(btrim(coalesce(p_closure_type,'')));
  v_summary text:=btrim(coalesce(p_resolution_summary,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_case_status text;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.close') then raise exception 'WhatsApp close permission required' using errcode='42501'; end if;
  if v_type not in ('RESOLVED','CANCELLED','DUPLICATE','NO_RESPONSE') then raise exception 'invalid case closure type'; end if;
  if length(v_summary)<10 or length(v_summary)>2000 then raise exception 'resolution summary required'; end if;
  if p_unresolved_items is null or jsonb_typeof(p_unresolved_items)<>'array' then raise exception 'unresolved items must be an array'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  select * into v_closure from public.whatsapp_case_closures where case_id=p_case_id;
  if found then return jsonb_build_object('case_id',p_case_id,'closure_id',v_closure.id,'case_status',v_case.status,'idempotent_replay',true); end if;

  if p_customer_notified then
    if p_closure_outbound_decision_id is null or not exists(
      select 1 from public.whatsapp_case_outbound_decisions d
      where d.id=p_closure_outbound_decision_id and d.case_id=p_case_id and d.status='RELEASED' and d.message_purpose='CASE_CLOSURE'
    ) then raise exception 'customer-notified closure requires released CASE_CLOSURE outbound decision'; end if;
  elsif p_closure_outbound_decision_id is not null then
    raise exception 'closure outbound decision cannot be supplied when customer_notified is false';
  end if;

  v_case_status:=case when v_type='CANCELLED' then 'CANCELLED' else 'CLOSED' end;
  insert into public.whatsapp_case_closures(case_id,closure_type,resolution_summary,unresolved_items,customer_notified,closure_outbound_decision_id,closed_by,closed_at,correlation_key)
  values(p_case_id,v_type,v_summary,p_unresolved_items,p_customer_notified,p_closure_outbound_decision_id,v_actor,statement_timestamp(),'case-close:'||v_key)
  returning * into v_closure;

  update public.whatsapp_communication_cases set status=v_case_status,closed_at=statement_timestamp(),next_action=null,next_action_due_at=null,updated_at=statement_timestamp()
  where id=p_case_id returning * into v_case;

  insert into public.whatsapp_case_milestone_events(case_id,milestone_type,occurred_at,customer_relevance,source,source_event_key,facts)
  values(p_case_id,case when v_type='CANCELLED' then 'CANCELLED' else 'CLOSED' end,statement_timestamp(),
    case when p_customer_notified then 'REQUIRED' else 'SILENT' end,'OPERATOR','case-close:'||v_key,
    jsonb_build_object('closure_type',v_type,'resolution_summary',v_summary))
  on conflict(case_id,source_event_key) do nothing;

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(p_case_id,'CASE_CLOSED',v_actor,'OPERATOR','case-close:'||v_key,
    jsonb_build_object('status',v_case_status,'closure_type',v_type),
    jsonb_build_object('closure_id',v_closure.id,'customer_notified',p_customer_notified,'unresolved_items',p_unresolved_items));

  return jsonb_build_object('case_id',p_case_id,'closure_id',v_closure.id,'case_status',v_case.status,'idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_close_case(uuid,text,text,jsonb,boolean,uuid,text) from public,anon,authenticated;
grant execute on function public.whatsapp_close_case(uuid,text,text,jsonb,boolean,uuid,text) to authenticated;


create or replace function public.whatsapp_run_shift_reconciliation(
  p_window_start timestamptz,
  p_window_end timestamptz,
  p_shift_code text,
  p_exception_due_at timestamptz,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_shift text:=upper(btrim(coalesce(p_shift_code,'')));
  v_run public.whatsapp_reconciliation_runs%rowtype;
  v_raw integer:=0;
  v_fragments integer:=0;
  v_cases integer:=0;
  v_orphans integer:=0;
  v_duplicates integer:=0;
  v_unresolved integer:=0;
  v_status text;
  r record;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.close') then raise exception 'WhatsApp close permission required for reconciliation' using errcode='42501'; end if;
  if p_window_start is null or p_window_end is null or p_window_end<=p_window_start then raise exception 'valid reconciliation window required'; end if;
  if p_window_end>statement_timestamp()+interval '5 minutes' then raise exception 'reconciliation window cannot materially extend into the future'; end if;
  if v_shift='' or length(v_shift)>80 then raise exception 'shift code required'; end if;
  if p_exception_due_at is null or p_exception_due_at<=statement_timestamp() then raise exception 'future exception due time required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_run from public.whatsapp_reconciliation_runs where correlation_key='case-reconcile:'||v_key;
  if found then return to_jsonb(v_run)||jsonb_build_object('idempotent_replay',true); end if;

  select count(*) into v_raw from public.whatsapp_inbound_messages i where i.received_at>=p_window_start and i.received_at<p_window_end;
  select count(*) into v_fragments from public.whatsapp_messages m where lower(m.direction)='inbound' and m.message_timestamp>=p_window_start at time zone 'UTC' and m.message_timestamp<p_window_end at time zone 'UTC' and m.packet_id is not null;
  select count(distinct c.id) into v_cases
  from public.whatsapp_communication_cases c
  join public.whatsapp_message_packets p on p.id=c.packet_id
  where p.first_message_at<p_window_end at time zone 'UTC' and p.last_message_at>=p_window_start at time zone 'UTC';
  select count(*) into v_orphans
  from public.whatsapp_inbound_messages i
  where i.received_at>=p_window_start and i.received_at<p_window_end
    and not exists(select 1 from public.whatsapp_messages m where m.provider_message_id=i.provider_message_id and lower(m.direction)='inbound');
  select greatest(v_fragments-count(distinct m.provider_message_id),0) into v_duplicates
  from public.whatsapp_messages m
  where lower(m.direction)='inbound' and m.message_timestamp>=p_window_start at time zone 'UTC' and m.message_timestamp<p_window_end at time zone 'UTC' and m.packet_id is not null;
  select count(*) into v_unresolved
  from public.whatsapp_message_packets p
  where p.first_message_at<p_window_end at time zone 'UTC' and p.last_message_at>=p_window_start at time zone 'UTC'
    and not exists(select 1 from public.whatsapp_communication_cases c where c.packet_id=p.id);

  v_status:=case when v_orphans=0 and v_unresolved=0 then 'ALIGNED' else 'EXCEPTIONS_OPEN' end;
  insert into public.whatsapp_reconciliation_runs(window_start,window_end,shift_code,raw_message_count,packet_fragment_count,case_source_count,orphan_message_count,duplicate_count,unresolved_count,status,reconciled_by,correlation_key)
  values(p_window_start,p_window_end,v_shift,v_raw,v_fragments,v_cases,v_orphans,v_duplicates,v_unresolved,v_status,v_actor,'case-reconcile:'||v_key)
  returning * into v_run;

  for r in
    select i.id,i.provider_message_id from public.whatsapp_inbound_messages i
    where i.received_at>=p_window_start and i.received_at<p_window_end
      and not exists(select 1 from public.whatsapp_messages m where m.provider_message_id=i.provider_message_id and lower(m.direction)='inbound')
  loop
    insert into public.whatsapp_reconciliation_exceptions(reconciliation_run_id,exception_type,business_object_type,business_object_id,details,owner_id,due_at)
    values(v_run.id,'ORPHAN_RAW_MESSAGE','whatsapp_inbound_messages',r.id,jsonb_build_object('provider_message_id',r.provider_message_id),v_actor,p_exception_due_at);
  end loop;

  for r in
    select p.id from public.whatsapp_message_packets p
    where p.first_message_at<p_window_end at time zone 'UTC' and p.last_message_at>=p_window_start at time zone 'UTC'
      and not exists(select 1 from public.whatsapp_communication_cases c where c.packet_id=p.id)
  loop
    insert into public.whatsapp_reconciliation_exceptions(reconciliation_run_id,exception_type,business_object_type,business_object_id,details,owner_id,due_at)
    values(v_run.id,'PACKET_WITHOUT_CASE','whatsapp_message_packets',r.id,jsonb_build_object('window_start',p_window_start,'window_end',p_window_end),v_actor,p_exception_due_at);
  end loop;

  return to_jsonb(v_run)||jsonb_build_object('idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_run_shift_reconciliation(timestamptz,timestamptz,text,timestamptz,text) from public,anon,authenticated;
grant execute on function public.whatsapp_run_shift_reconciliation(timestamptz,timestamptz,text,timestamptz,text) to authenticated;


create or replace function public.whatsapp_resolve_reconciliation_exception(
  p_exception_id uuid,
  p_resolution text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_item public.whatsapp_reconciliation_exceptions%rowtype;
  v_resolution text:=btrim(coalesce(p_resolution,''));
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.close') then raise exception 'WhatsApp close permission required' using errcode='42501'; end if;
  if length(v_resolution)<5 or length(v_resolution)>1000 then raise exception 'resolution required'; end if;
  select * into v_item from public.whatsapp_reconciliation_exceptions where id=p_exception_id for update;
  if not found then raise exception 'reconciliation exception not found'; end if;
  if v_item.resolved_at is null then
    update public.whatsapp_reconciliation_exceptions set resolved_at=statement_timestamp(),resolved_by=v_actor,resolution=v_resolution where id=v_item.id returning * into v_item;
  end if;
  return to_jsonb(v_item);
end;
$$;
revoke all on function public.whatsapp_resolve_reconciliation_exception(uuid,text) from public,anon,authenticated;
grant execute on function public.whatsapp_resolve_reconciliation_exception(uuid,text) to authenticated;


create or replace function public.whatsapp_signoff_reconciliation(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_run public.whatsapp_reconciliation_runs%rowtype;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.close') then raise exception 'WhatsApp close permission required' using errcode='42501'; end if;
  select * into v_run from public.whatsapp_reconciliation_runs where id=p_run_id for update;
  if not found then raise exception 'reconciliation run not found'; end if;
  if exists(select 1 from public.whatsapp_reconciliation_exceptions e where e.reconciliation_run_id=p_run_id and e.resolved_at is null) then
    raise exception 'reconciliation has open exceptions';
  end if;
  update public.whatsapp_reconciliation_runs set status='SIGNED_OFF',signed_off_by=v_actor,signed_off_at=statement_timestamp() where id=p_run_id returning * into v_run;
  return to_jsonb(v_run);
end;
$$;
revoke all on function public.whatsapp_signoff_reconciliation(uuid) from public,anon,authenticated;
grant execute on function public.whatsapp_signoff_reconciliation(uuid) to authenticated;


create or replace function public.whatsapp_get_case_decision_snapshot(p_packet_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_ai jsonb;
  v_identities jsonb;
  v_authorizations jsonb;
  v_tasks jsonb;
  v_clarifications jsonb;
  v_escalations jsonb;
  v_outbound jsonb;
  v_milestones jsonb;
  v_closure jsonb;
  v_events jsonb;
begin
  if v_actor is null or not public.is_whatsapp_inbox_reader(v_actor) then raise exception 'WhatsApp inbox read permission required' using errcode='42501'; end if;
  select * into v_case from public.whatsapp_communication_cases where packet_id=p_packet_id;
  if not found then return jsonb_build_object('packet_id',p_packet_id,'case',null); end if;
  select to_jsonb(x) into v_ai from (select id,content_fingerprint,provider_message_ids,interpretation,model_version,created_at from public.whatsapp_packet_ai_interpretations where packet_id=p_packet_id order by created_at desc,id desc limit 1) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb) into v_identities from (select id,identity_role,party_type,party_id,display_label,phone_e164,resolution_status,confidence,evidence,created_at from public.whatsapp_case_identities where case_id=v_case.id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb) into v_authorizations from (select id,identity_id,disclosure_scope,may_receive_clarification,may_confirm_commercial_scope,verification_method,verified_by,verified_at,revoked_at,correlation_key,created_at from public.whatsapp_case_recipient_authorizations where case_id=v_case.id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb) into v_tasks from (select id,department,assigned_user_id,task_type,instructions,status,due_at,response_payload,completed_by,completed_at,correlation_key,created_by,created_at,updated_at from public.whatsapp_case_department_tasks where case_id=v_case.id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb) into v_clarifications from (select id,field_name,question,recipient_authorization_id,status,due_at,next_follow_up_at,asked_by,asked_at,source_outbound_message_id,answer_text,answered_at,correlation_key,created_at from public.whatsapp_case_clarifications where case_id=v_case.id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb) into v_escalations from (select id,department_task_id,escalation_level,reason,escalated_to_team,escalated_to_user_id,due_at,acknowledged_at,resolved_at,resolution,correlation_key,created_at from public.whatsapp_case_escalations where case_id=v_case.id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb) into v_outbound from (select d.id,d.recipient_authorization_id,d.message_purpose,d.disclosure_scope,d.message_body,d.status,d.idempotency_key,d.created_at,d.validated_at,d.released_by,d.released_at,d.related_clarification_id,d.related_milestone_event_id,(select o.status from public.whatsapp_operator_reply_outbox o where o.packet_id=v_case.packet_id and o.idempotency_key='case:'||d.id::text order by o.created_at desc limit 1) as provider_status,(select o.id from public.whatsapp_operator_reply_outbox o where o.packet_id=v_case.packet_id and o.idempotency_key='case:'||d.id::text order by o.created_at desc limit 1) as wa5_reply_id from public.whatsapp_case_outbound_decisions d where d.case_id=v_case.id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at,x.id),'[]'::jsonb) into v_milestones from (select id,milestone_type,business_object_type,business_object_id,occurred_at,customer_relevance,source,source_event_key,facts from public.whatsapp_case_milestone_events where case_id=v_case.id) x;
  select to_jsonb(x) into v_closure from (select id,closure_type,resolution_summary,unresolved_items,customer_notified,closure_outbound_decision_id,closed_by,closed_at,correlation_key from public.whatsapp_case_closures where case_id=v_case.id limit 1) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc,x.id desc),'[]'::jsonb) into v_events from (select id,event_type,actor_id,actor_type,correlation_key,prior_state,resulting_state,metadata,occurred_at,recorded_at from public.whatsapp_case_events where case_id=v_case.id order by occurred_at desc,id desc limit 100) x;
  return jsonb_build_object('packet_id',p_packet_id,'case',to_jsonb(v_case),'latest_ai',v_ai,'identities',v_identities,
    'recipient_authorizations',v_authorizations,'department_tasks',v_tasks,'clarifications',v_clarifications,
    'escalations',v_escalations,'outbound_decisions',v_outbound,'milestones',v_milestones,'closure',v_closure,'events',v_events);
end;
$$;
comment on function public.whatsapp_get_case_decision_snapshot(uuid) is
  'Read-only full B2B Decision Desk snapshot: advisory AI, identity authority, accountability, clarification, outbound, escalation, milestones and closure.';
revoke all on function public.whatsapp_get_case_decision_snapshot(uuid) from public,anon;
grant execute on function public.whatsapp_get_case_decision_snapshot(uuid) to authenticated;
