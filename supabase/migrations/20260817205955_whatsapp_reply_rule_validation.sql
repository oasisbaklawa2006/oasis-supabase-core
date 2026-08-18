-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260818010700_whatsapp_reply_rule_validation.sql (head 3b013b4); comment/whitespace-only delta consistent with pattern.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- Replace operator self-certification of outbound case replies with deterministic
-- server validation. Low-risk replies still require a human send action. Replies that
-- contain unresolved ambiguity or commitment-bearing wording remain DRAFT until an
-- authorised human supplies explicit evidence and performs a second reviewed release.

create or replace function public.whatsapp_rule_validate_case_reply(
  p_case_id uuid,
  p_recipient_authorization_id uuid,
  p_message_purpose text,
  p_message_body text,
  p_disclosure_scope text[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path=pg_catalog,public
as $$
declare
  v_case public.whatsapp_communication_cases%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
  v_body text:=btrim(coalesce(p_message_body,''));
  v_purpose text:=upper(btrim(coalesce(p_message_purpose,'')));
  v_scope text[]:=coalesce(p_disclosure_scope,'{}'::text[]);
  v_factual text:='PASS';
  v_recipient text:='PASS';
  v_disclosure text:='PASS';
  v_ambiguity text:='PASS';
  v_commitment text:='NONE';
  v_findings jsonb:='[]'::jsonb;
  v_latest_ai jsonb;
  v_ambiguity_count integer:=0;
  v_open_clarifications integer:=0;
  v_risky boolean:=false;
begin
  select * into v_case from public.whatsapp_communication_cases where id=p_case_id;
  if not found then raise exception 'WhatsApp communication case not found'; end if;

  select * into v_auth from public.whatsapp_case_recipient_authorizations
  where id=p_recipient_authorization_id and case_id=p_case_id;
  if not found or v_auth.revoked_at is not null then
    v_recipient:='FAIL';
    v_findings:=v_findings||jsonb_build_array(jsonb_build_object('code','RECIPIENT_AUTHORITY_MISSING','severity','BLOCK'));
  elsif not v_scope<@v_auth.disclosure_scope then
    v_disclosure:='FAIL';
    v_findings:=v_findings||jsonb_build_array(jsonb_build_object('code','DISCLOSURE_SCOPE_EXCEEDED','severity','BLOCK'));
  end if;

  select count(*) into v_open_clarifications
  from public.whatsapp_case_clarifications
  where case_id=p_case_id and status='OPEN';

  select ai.interpretation into v_latest_ai
  from public.whatsapp_packet_ai_interpretations ai
  where ai.packet_id=v_case.packet_id
  order by ai.created_at desc,ai.id desc limit 1;
  v_ambiguity_count:=case
    when jsonb_typeof(v_latest_ai #> '{conclusion,ambiguities}')='array'
      then jsonb_array_length(v_latest_ai #> '{conclusion,ambiguities}')
    else 0 end;

  if v_purpose not in ('RECEIPT_ACKNOWLEDGEMENT','CASE_CLOSURE')
     and (v_open_clarifications>0 or v_ambiguity_count>0) then
    v_ambiguity:='REVIEW_REQUIRED';
    v_findings:=v_findings||jsonb_build_array(jsonb_build_object(
      'code','CASE_HAS_UNRESOLVED_AMBIGUITY','severity','REVIEW',
      'open_clarifications',v_open_clarifications,'ai_ambiguities',v_ambiguity_count));
  end if;

  v_risky:=v_body ~* '((payment|utr)[^\n.]{0,40}(verified|confirmed|received)|credit[^\n.]{0,30}(approved|confirmed)|(^|[^a-z])(in stock|stock available|available stock)([^a-z]|$)|will[[:space:]]+(dispatch|deliver)|dispatch[[:space:]]+by|delivery[[:space:]]+by|guaranteed[[:space:]]+delivery|(^|[^a-z])(price|rate)[[:space:]]+(is|will be)|₹|(^|[^a-z])rs\.?([^a-z]|$))';

  if v_risky then
    v_factual:='REVIEW_REQUIRED';
    v_findings:=v_findings||jsonb_build_array(jsonb_build_object(
      'code','COMMITMENT_BEARING_WORDING_REQUIRES_EVIDENCE','severity','REVIEW'));
  end if;

  if cardinality(v_scope)>0 then
    v_commitment:=case when v_recipient='PASS' and v_disclosure='PASS' then 'AUTHORISED' else 'UNAUTHORISED' end;
  elsif v_risky then
    v_commitment:='UNAUTHORISED';
  end if;

  return jsonb_build_object(
    'factual_consistency_status',v_factual,
    'recipient_authority_status',v_recipient,
    'disclosure_status',v_disclosure,
    'ambiguity_status',v_ambiguity,
    'commercial_commitment_status',v_commitment,
    'findings',v_findings,
    'review_required',v_factual='REVIEW_REQUIRED' or v_ambiguity='REVIEW_REQUIRED' or v_commitment='UNAUTHORISED'
  );
end;
$$;
revoke all on function public.whatsapp_rule_validate_case_reply(uuid,uuid,text,text,text[]) from public,anon,authenticated;
grant execute on function public.whatsapp_rule_validate_case_reply(uuid,uuid,text,text,text[]) to service_role;


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
set search_path=pg_catalog,public,auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
  v_decision public.whatsapp_case_outbound_decisions%rowtype;
  v_reply public.whatsapp_operator_reply_outbox%rowtype;
  v_purpose text:=upper(btrim(coalesce(p_message_purpose,'')));
  v_body text:=btrim(coalesce(p_message_body,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_scope text[];
  v_potential_order_id uuid;
  v_validation jsonb;
  v_review_required boolean;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.reply.send') then raise exception 'WhatsApp reply permission required' using errcode='42501'; end if;
  if v_purpose not in ('RECEIPT_ACKNOWLEDGEMENT','OPERATIONAL_MILESTONE','CASE_UPDATE','CASE_CLOSURE') then raise exception 'unsupported case reply purpose'; end if;
  if length(v_body)<1 or length(v_body)>4000 then raise exception 'reply body required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;
  if (v_purpose='OPERATIONAL_MILESTONE')<>(p_related_milestone_event_id is not null) then raise exception 'operational milestone reply requires exactly one related milestone'; end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') and v_purpose<>'CASE_CLOSURE' then raise exception 'closed case cannot send update'; end if;

  if exists(select 1 from public.whatsapp_case_events where case_id=p_case_id and correlation_key='case-reply:'||v_key) then
    select * into v_decision from public.whatsapp_case_outbound_decisions where case_id=p_case_id and idempotency_key='case-reply:'||v_key;
    select * into v_reply from public.whatsapp_operator_reply_outbox where packet_id=v_case.packet_id and idempotency_key='case:'||v_decision.id::text;
    return jsonb_build_object('case_id',p_case_id,'outbound_decision_id',v_decision.id,'decision_status',v_decision.status,
      'reply_id',v_reply.id,'reply_status',v_reply.status,'review_required',v_decision.status='DRAFT','idempotent_replay',true);
  end if;

  select * into v_auth from public.whatsapp_case_recipient_authorizations where id=p_recipient_authorization_id and case_id=p_case_id for share;
  if not found or v_auth.revoked_at is not null then raise exception 'active recipient authorization required'; end if;
  select coalesce(array_agg(distinct scope order by scope),'{}'::text[]) into v_scope
  from unnest(coalesce(p_disclosure_scope,'{}'::text[])||coalesce(public.wa6_infer_commercial_disclosure(v_body),'{}'::text[])) scope where btrim(scope)<>'';
  if not v_scope<@v_auth.disclosure_scope then raise exception 'reply disclosure exceeds recipient authority'; end if;
  if p_related_milestone_event_id is not null and not exists(select 1 from public.whatsapp_case_milestone_events m where m.id=p_related_milestone_event_id and m.case_id=p_case_id) then raise exception 'milestone belongs to another case'; end if;

  select * into v_packet from public.whatsapp_message_packets where id=v_case.packet_id;
  select * into v_contact from public.whatsapp_contacts where id=v_packet.contact_id;
  if v_packet.id is null or v_contact.id is null then raise exception 'case packet/contact boundary missing'; end if;
  v_potential_order_id:=public.whatsapp_case_potential_order_id(p_case_id);
  if cardinality(v_scope)>0 and v_potential_order_id is null then raise exception 'commercial reply requires one governed potential order'; end if;

  insert into public.whatsapp_case_outbound_decisions(
    case_id,recipient_authorization_id,message_purpose,disclosure_scope,message_body,related_milestone_event_id,status,idempotency_key,rule_version,created_by
  ) values(
    p_case_id,p_recipient_authorization_id,v_purpose,v_scope,v_body,p_related_milestone_event_id,'DRAFT','case-reply:'||v_key,'b2b-case-rule-validation-v2',v_actor
  ) returning * into v_decision;

  v_validation:=public.whatsapp_rule_validate_case_reply(p_case_id,p_recipient_authorization_id,v_purpose,v_body,v_scope);
  v_review_required:=coalesce((v_validation->>'review_required')::boolean,false)
    or v_validation->>'factual_consistency_status'='FAIL'
    or v_validation->>'recipient_authority_status'='FAIL'
    or v_validation->>'disclosure_status'='FAIL'
    or v_validation->>'ambiguity_status'='FAIL'
    or v_validation->>'commercial_commitment_status'='UNAUTHORISED';

  insert into public.whatsapp_case_reply_validations(
    outbound_decision_id,validation_version,factual_consistency_status,recipient_authority_status,disclosure_status,
    ambiguity_status,commercial_commitment_status,validator_type,validator_version,findings,validated_by,correlation_key
  ) values(
    v_decision.id,1,v_validation->>'factual_consistency_status',v_validation->>'recipient_authority_status',
    v_validation->>'disclosure_status',v_validation->>'ambiguity_status',v_validation->>'commercial_commitment_status',
    'RULE','b2b-case-rule-validation-v2',v_validation->'findings',null,'case-reply:'||v_key||':rule-validation'
  );

  if v_review_required then
    insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
    values(p_case_id,'CASE_REPLY_REVIEW_REQUIRED',v_actor,'OPERATOR','case-reply:'||v_key,
      jsonb_build_object('outbound_decision_id',v_decision.id,'status','DRAFT'),
      jsonb_build_object('validation',v_validation,'human_evidence_required',true));
    return jsonb_build_object('case_id',p_case_id,'outbound_decision_id',v_decision.id,'decision_status','DRAFT',
      'reply_id',null,'reply_status',null,'review_required',true,'validation',v_validation,'idempotent_replay',false);
  end if;

  update public.whatsapp_case_outbound_decisions
  set status='RELEASED',validated_at=statement_timestamp(),released_by=v_actor,released_at=statement_timestamp()
  where id=v_decision.id returning * into v_decision;
  v_reply:=public.enqueue_whatsapp_operator_reply(v_packet.id,v_contact.id,'+'||regexp_replace(v_contact.phone_number,'\\D','','g'),v_body,
    'case:'||v_decision.id::text,v_potential_order_id,null,'TEXT',null,null,null,v_scope);
  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(p_case_id,'CASE_REPLY_RELEASED',v_actor,'OPERATOR','case-reply:'||v_key,
    jsonb_build_object('message_purpose',v_purpose,'reply_status',v_reply.status),
    jsonb_build_object('outbound_decision_id',v_decision.id,'wa5_reply_id',v_reply.id,'disclosure_scope',to_jsonb(v_scope),'validator','RULE'));
  return jsonb_build_object('case_id',p_case_id,'outbound_decision_id',v_decision.id,'decision_status','RELEASED',
    'reply_id',v_reply.id,'reply_status',v_reply.status,'review_required',false,'validation',v_validation,'idempotent_replay',false);
end;
$$;


create or replace function public.whatsapp_release_reviewed_case_reply(
  p_outbound_decision_id uuid,
  p_evidence jsonb,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_decision public.whatsapp_case_outbound_decisions%rowtype;
  v_case public.whatsapp_communication_cases%rowtype;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
  v_reply public.whatsapp_operator_reply_outbox%rowtype;
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_potential_order_id uuid;
  v_risky boolean;
  v_findings jsonb;
  v_version integer;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.reply.send') then raise exception 'WhatsApp reply permission required' using errcode='42501'; end if;
  if p_evidence is null or jsonb_typeof(p_evidence)<>'object' or p_evidence='{}'::jsonb then raise exception 'review evidence required'; end if;
  if nullif(btrim(coalesce(p_evidence->>'evidence_reference','')),'') is null
     or nullif(btrim(coalesce(p_evidence->>'decision_basis','')),'') is null then
    raise exception 'review evidence reference and decision basis required';
  end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_decision from public.whatsapp_case_outbound_decisions where id=p_outbound_decision_id for update;
  if not found then raise exception 'outbound decision not found'; end if;
  select * into v_case from public.whatsapp_communication_cases where id=v_decision.case_id;
  if not found then raise exception 'WhatsApp communication case not found'; end if;

  if v_decision.status='RELEASED' then
    select * into v_reply from public.whatsapp_operator_reply_outbox where packet_id=v_case.packet_id and idempotency_key='case:'||v_decision.id::text;
    return jsonb_build_object('case_id',v_case.id,'outbound_decision_id',v_decision.id,'decision_status','RELEASED',
      'reply_id',v_reply.id,'reply_status',v_reply.status,'idempotent_replay',true);
  end if;
  if v_decision.status<>'DRAFT' then raise exception 'only a draft outbound decision can be reviewed for release'; end if;
  if exists(select 1 from public.whatsapp_case_events where case_id=v_case.id and correlation_key='case-reviewed-release:'||v_key) then
    return jsonb_build_object('case_id',v_case.id,'outbound_decision_id',v_decision.id,'decision_status',v_decision.status,'idempotent_replay',true);
  end if;

  select * into v_auth from public.whatsapp_case_recipient_authorizations
  where id=v_decision.recipient_authorization_id and case_id=v_case.id and revoked_at is null for share;
  if not found then raise exception 'active recipient authorization required'; end if;
  if not v_decision.disclosure_scope<@v_auth.disclosure_scope then raise exception 'reply disclosure exceeds recipient authority'; end if;

  v_risky:=v_decision.message_body ~* '((payment|utr)[^\n.]{0,40}(verified|confirmed|received)|credit[^\n.]{0,30}(approved|confirmed)|(^|[^a-z])(in stock|stock available|available stock)([^a-z]|$)|will[[:space:]]+(dispatch|deliver)|dispatch[[:space:]]+by|delivery[[:space:]]+by|guaranteed[[:space:]]+delivery|(^|[^a-z])(price|rate)[[:space:]]+(is|will be)|₹|(^|[^a-z])rs\.?([^a-z]|$))';
  if (v_risky or cardinality(v_decision.disclosure_scope)>0)
     and not public.has_whatsapp_permission('wa.disclosure.authorize') then
    raise exception 'step-up commercial disclosure authority required' using errcode='42501';
  end if;

  select coalesce(max(validation_version),0)+1 into v_version
  from public.whatsapp_case_reply_validations where outbound_decision_id=v_decision.id;
  v_findings:=jsonb_build_array(jsonb_build_object('code','HUMAN_EVIDENCE_REVIEW','severity','PASS','evidence',p_evidence));
  insert into public.whatsapp_case_reply_validations(
    outbound_decision_id,validation_version,factual_consistency_status,recipient_authority_status,disclosure_status,
    ambiguity_status,commercial_commitment_status,validator_type,validator_version,findings,validated_by,correlation_key
  ) values(
    v_decision.id,v_version,'PASS','PASS','PASS','PASS',case when cardinality(v_decision.disclosure_scope)>0 or v_risky then 'AUTHORISED' else 'NONE' end,
    'OPERATOR','human-evidence-review-v1',v_findings,v_actor,'reviewed-release:'||v_key
  );

  update public.whatsapp_case_outbound_decisions
  set status='RELEASED',validated_at=statement_timestamp(),released_by=v_actor,released_at=statement_timestamp(),rule_version='b2b-case-reviewed-release-v1'
  where id=v_decision.id returning * into v_decision;
  select * into v_packet from public.whatsapp_message_packets where id=v_case.packet_id;
  select * into v_contact from public.whatsapp_contacts where id=v_packet.contact_id;
  if v_packet.id is null or v_contact.id is null then raise exception 'case packet/contact boundary missing'; end if;
  v_potential_order_id:=public.whatsapp_case_potential_order_id(v_case.id);
  if cardinality(v_decision.disclosure_scope)>0 and v_potential_order_id is null then raise exception 'commercial reply requires one governed potential order'; end if;

  v_reply:=public.enqueue_whatsapp_operator_reply(v_packet.id,v_contact.id,'+'||regexp_replace(v_contact.phone_number,'\\D','','g'),v_decision.message_body,
    'case:'||v_decision.id::text,v_potential_order_id,null,'TEXT',null,null,null,v_decision.disclosure_scope);
  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(v_case.id,'CASE_REPLY_RELEASED_AFTER_REVIEW',v_actor,'OPERATOR','case-reviewed-release:'||v_key,
    jsonb_build_object('outbound_decision_id',v_decision.id,'reply_status',v_reply.status),
    jsonb_build_object('wa5_reply_id',v_reply.id,'evidence',p_evidence,'disclosure_scope',to_jsonb(v_decision.disclosure_scope)));
  return jsonb_build_object('case_id',v_case.id,'outbound_decision_id',v_decision.id,'decision_status','RELEASED',
    'reply_id',v_reply.id,'reply_status',v_reply.status,'idempotent_replay',false);
end;
$$;

revoke all on function public.whatsapp_release_reviewed_case_reply(uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.whatsapp_release_reviewed_case_reply(uuid,jsonb,text) to authenticated;
