-- Forward-only defect closure: WhatsApp authority and security hardening.
-- Closes defects surfaced by PR #89 review and deliberately deferred
-- (byte-faithful lineage preservation forbade fixing them in the recovered
-- historical files that introduced them). Documented in
-- docs/reconciliation/production-migration-lineage-recovery-2026-08-18.md
-- under "Pre-existing production bugs surfaced by review".
--
-- =================================================================================
-- disclosure_scope NULL fail-open bypass -- RE-AUDITED, RECLASSIFIED
-- FALSE_POSITIVE against the current schema, fixed anyway as harmless
-- defense-in-depth:
--
-- PR #89 review flagged `not <scope> <@ v_auth.disclosure_scope` as a
-- fail-open bypass if disclosure_scope were NULL (PostgreSQL's containment
-- operator returns NULL on a NULL operand, so `not NULL` is NULL and the
-- `if` body never runs). Re-checking the actual schema before writing this
-- migration: both whatsapp_case_recipient_authorizations.disclosure_scope
-- and whatsapp_case_outbound_decisions.disclosure_scope are declared
-- `text[] NOT NULL DEFAULT '{}'` where first created
-- (20260727070135_production_reconciliation_whatsapp_patch_03.sql,
-- 20260727070140_production_reconciliation_whatsapp_patch_04.sql), and no
-- migration in this repository ever relaxes that constraint. A row that
-- exists in either table therefore cannot have a NULL disclosure_scope --
-- the bypass as literally described is not reachable today.
--
-- Applying `coalesce(..., '{}'::text[])` anyway at all three outbound
-- authority gates (whatsapp_ask_customer and whatsapp_release_case_reply
-- from the original review, plus whatsapp_release_reviewed_case_reply found
-- by re-auditing every outbound gate in this migration): it is a genuine
-- no-op today given the NOT NULL constraint, costs nothing, and stops each
-- function's authorization logic from silently depending on a constraint
-- enforced elsewhere in the schema rather than in the function itself --
-- defense-in-depth against any future ALTER TABLE that relaxes NOT NULL,
-- not a fix for an active vulnerability.
--
-- whatsapp_release_case_reply also gets its phone-normalization regex
-- corrected in this same CREATE OR REPLACE (the escaped-backslash
-- '\\D' bug -- see the sibling normalization migration for the other two
-- sites of the same bug class) and the missing REVOKE/GRANT pair every
-- other function in this cohort has, since a second migration touching the
-- same function body afterward would otherwise have to be based on this
-- one's output, not the older recovered one, per the requirement that every
-- CREATE OR REPLACE reproduce the entire final intended definition.
-- =================================================================================

-- ---------------------------------------------------------------------------------
-- whatsapp_ask_customer: fail-closed disclosure_scope containment check.
-- Full definition reproduced from the last (only) effective version
-- (supabase/migrations/20260817193859_whatsapp_b2b_case_decision_lifecycle.sql)
-- with only the containment check changed.
-- ---------------------------------------------------------------------------------

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
  if not v_scope <@ coalesce(v_auth.disclosure_scope, '{}'::text[]) then raise exception 'clarification disclosure exceeds recipient authority'; end if;

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

-- ---------------------------------------------------------------------------------
-- whatsapp_release_case_reply: fail-closed disclosure_scope containment
-- check, correct phone-normalization regex, and the missing REVOKE/GRANT
-- pair (PostgreSQL grants EXECUTE to PUBLIC by default; the internal
-- has_whatsapp_permission() check still blocks effects, so this was a
-- least-privilege gap, not an authorization bypass, but the database ACL
-- must be correct as defense-in-depth).
--
-- Full definition reproduced from the LAST effective version
-- (supabase/migrations/20260817205955_whatsapp_reply_rule_validation.sql,
-- which redefines the function originally created in
-- 20260817193859_whatsapp_b2b_case_decision_lifecycle.sql -- not that
-- earlier version) with only the containment check and the regex changed.
-- ---------------------------------------------------------------------------------

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
  if not v_scope<@coalesce(v_auth.disclosure_scope, '{}'::text[]) then raise exception 'reply disclosure exceeds recipient authority'; end if;
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
  v_reply:=public.enqueue_whatsapp_operator_reply(v_packet.id,v_contact.id,'+'||regexp_replace(v_contact.phone_number,'\D','','g'),v_body,
    'case:'||v_decision.id::text,v_potential_order_id,null,'TEXT',null,null,null,v_scope);
  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(p_case_id,'CASE_REPLY_RELEASED',v_actor,'OPERATOR','case-reply:'||v_key,
    jsonb_build_object('message_purpose',v_purpose,'reply_status',v_reply.status),
    jsonb_build_object('outbound_decision_id',v_decision.id,'wa5_reply_id',v_reply.id,'disclosure_scope',to_jsonb(v_scope),'validator','RULE'));
  return jsonb_build_object('case_id',p_case_id,'outbound_decision_id',v_decision.id,'decision_status','RELEASED',
    'reply_id',v_reply.id,'reply_status',v_reply.status,'review_required',false,'validation',v_validation,'idempotent_replay',false);
end;
$$;

revoke all on function public.whatsapp_release_case_reply(uuid,uuid,text,text,text[],uuid,text)
  from public,anon,authenticated;
grant execute on function public.whatsapp_release_case_reply(uuid,uuid,text,text,text[],uuid,text)
  to authenticated;

-- ---------------------------------------------------------------------------------
-- whatsapp_release_reviewed_case_reply: fail-closed disclosure_scope
-- containment check (v_auth.disclosure_scope, the same nullable column, the
-- same unguarded pattern -- found during this migration's own re-audit of
-- every outbound authority gate, not in the original PR #89 review) and the
-- same regex correction. Grants were already correct on this function.
--
-- Full definition reproduced from the last (only) effective version
-- (supabase/migrations/20260817205955_whatsapp_reply_rule_validation.sql)
-- with only the containment check and the regex changed.
-- ---------------------------------------------------------------------------------

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
  if not v_decision.disclosure_scope<@coalesce(v_auth.disclosure_scope, '{}'::text[]) then raise exception 'reply disclosure exceeds recipient authority'; end if;

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

  v_reply:=public.enqueue_whatsapp_operator_reply(v_packet.id,v_contact.id,'+'||regexp_replace(v_contact.phone_number,'\D','','g'),v_decision.message_body,
    'case:'||v_decision.id::text,v_potential_order_id,null,'TEXT',null,null,null,v_decision.disclosure_scope);
  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(v_case.id,'CASE_REPLY_RELEASED_AFTER_REVIEW',v_actor,'OPERATOR','case-reviewed-release:'||v_key,
    jsonb_build_object('outbound_decision_id',v_decision.id,'reply_status',v_reply.status),
    jsonb_build_object('wa5_reply_id',v_reply.id,'evidence',p_evidence,'disclosure_scope',to_jsonb(v_decision.disclosure_scope)));
  return jsonb_build_object('case_id',v_case.id,'outbound_decision_id',v_decision.id,'decision_status','RELEASED',
    'reply_id',v_reply.id,'reply_status',v_reply.status,'idempotent_replay',false);
end;
$$;

-- =================================================================================
-- Grants unchanged from the last effective version of each function
-- (CREATE OR REPLACE FUNCTION preserves existing ACLs, so these are
-- functionally no-ops); restated explicitly for consistency with
-- whatsapp_release_case_reply above and the rest of this migration, per
-- Codacy review.
-- =================================================================================

revoke all on function public.whatsapp_ask_customer(uuid,uuid,text,text,timestamptz,text[],text) from public,anon,authenticated;
grant execute on function public.whatsapp_ask_customer(uuid,uuid,text,text,timestamptz,text[],text) to authenticated;

revoke all on function public.whatsapp_release_reviewed_case_reply(uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.whatsapp_release_reviewed_case_reply(uuid,jsonb,text) to authenticated;
