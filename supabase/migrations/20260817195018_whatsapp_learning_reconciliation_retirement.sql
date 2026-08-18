-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260818010300_whatsapp_learning_reconciliation_retirement.sql (head 3b013b4); comment/whitespace-only delta consistent with pattern.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- Complete the operational governance around reconciliation visibility, learning
-- candidates and append-only legacy retirement evidence. These functions never
-- promote a learning candidate into a canonical object themselves.

create or replace function public.whatsapp_get_reconciliation_run(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_run jsonb;
  v_exceptions jsonb;
begin
  if v_actor is null or not public.is_whatsapp_inbox_reader(v_actor) then
    raise exception 'WhatsApp inbox read permission required' using errcode='42501';
  end if;

  select to_jsonb(r) into v_run
  from public.whatsapp_reconciliation_runs r
  where r.id=p_run_id;
  if v_run is null then raise exception 'reconciliation run not found'; end if;

  select coalesce(jsonb_agg(to_jsonb(e) order by e.resolved_at nulls first,e.due_at,e.created_at,e.id),'[]'::jsonb)
  into v_exceptions
  from public.whatsapp_reconciliation_exceptions e
  where e.reconciliation_run_id=p_run_id;

  return jsonb_build_object('run',v_run,'exceptions',v_exceptions);
end;
$$;
revoke all on function public.whatsapp_get_reconciliation_run(uuid) from public,anon;
grant execute on function public.whatsapp_get_reconciliation_run(uuid) to authenticated;


create or replace function public.whatsapp_capture_learning_candidate(
  p_case_id uuid,
  p_source_message_id uuid,
  p_candidate_type text,
  p_observed_value text,
  p_proposed_mapping jsonb,
  p_evidence jsonb,
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
  v_candidate public.whatsapp_learning_candidates%rowtype;
  v_type text:=upper(btrim(coalesce(p_candidate_type,'')));
  v_observed text:=btrim(coalesce(p_observed_value,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WhatsApp triage permission required' using errcode='42501';
  end if;
  if v_type not in ('PRODUCT_ALIAS','CUSTOMER_ALIAS','INTENT_PATTERN','QUANTITY_PATTERN') then raise exception 'unsupported learning candidate type'; end if;
  if length(v_observed)<1 or length(v_observed)>500 then raise exception 'observed learning value required'; end if;
  if p_proposed_mapping is null or jsonb_typeof(p_proposed_mapping)<>'object' or p_proposed_mapping='{}'::jsonb then raise exception 'proposed mapping object required'; end if;
  if p_evidence is null or jsonb_typeof(p_evidence)<>'object' or p_evidence='{}'::jsonb then raise exception 'learning evidence object required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id;
  if not found then raise exception 'WhatsApp communication case not found'; end if;

  if p_source_message_id is not null and not exists(
    select 1 from public.whatsapp_messages m
    where m.id=p_source_message_id and m.packet_id=v_case.packet_id and lower(m.direction)='inbound'
  ) then raise exception 'learning source message is outside the communication case packet'; end if;

  insert into public.whatsapp_learning_candidates(
    case_id,source_message_id,candidate_type,observed_value,proposed_mapping,evidence,
    inference_ruleset_version,status,correlation_key
  ) values (
    p_case_id,p_source_message_id,v_type,v_observed,p_proposed_mapping,p_evidence,
    v_case.rule_version,'PENDING_REVIEW','learning:'||v_key
  )
  on conflict(correlation_key) do nothing;

  select * into v_candidate from public.whatsapp_learning_candidates where correlation_key='learning:'||v_key;
  if v_candidate.case_id<>p_case_id then raise exception 'learning idempotency key belongs to another case'; end if;

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(p_case_id,'LEARNING_CANDIDATE_CAPTURED',v_actor,'OPERATOR','learning-captured:'||v_key,
    jsonb_build_object('learning_candidate_id',v_candidate.id,'candidate_type',v_type,'status',v_candidate.status),
    jsonb_build_object('observed_value',v_observed,'promotion_not_performed',true))
  on conflict(case_id,correlation_key) do nothing;

  return to_jsonb(v_candidate);
end;
$$;
revoke all on function public.whatsapp_capture_learning_candidate(uuid,uuid,text,text,jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function public.whatsapp_capture_learning_candidate(uuid,uuid,text,text,jsonb,jsonb,text) to authenticated;


create or replace function public.whatsapp_review_learning_candidate(
  p_candidate_id uuid,
  p_decision text,
  p_reason text,
  p_promoted_object_type text default null,
  p_promoted_object_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_candidate public.whatsapp_learning_candidates%rowtype;
  v_decision text:=upper(btrim(coalesce(p_decision,'')));
  v_reason text:=btrim(coalesce(p_reason,''));
  v_status text;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.assign') then
    raise exception 'WhatsApp assignment authority required for learning review' using errcode='42501';
  end if;
  if v_decision not in ('APPROVE_REFERENCE','REJECT','SUPERSEDE') then raise exception 'invalid learning review decision'; end if;
  if length(v_reason)<5 or length(v_reason)>1000 then raise exception 'learning review reason required'; end if;
  if v_decision='APPROVE_REFERENCE' and (nullif(btrim(coalesce(p_promoted_object_type,'')),'') is null or p_promoted_object_id is null) then
    raise exception 'approved learning requires an already-created canonical object reference';
  end if;
  if v_decision<>'APPROVE_REFERENCE' and (p_promoted_object_type is not null or p_promoted_object_id is not null) then
    raise exception 'non-approved learning cannot carry a promoted object reference';
  end if;

  select * into v_candidate from public.whatsapp_learning_candidates where id=p_candidate_id for update;
  if not found then raise exception 'learning candidate not found'; end if;
  if v_candidate.status<>'PENDING_REVIEW' then raise exception 'learning candidate has already been reviewed'; end if;

  v_status:=case v_decision when 'APPROVE_REFERENCE' then 'APPROVED' when 'REJECT' then 'REJECTED' else 'SUPERSEDED' end;
  update public.whatsapp_learning_candidates
  set status=v_status,reviewed_by=v_actor,reviewed_at=statement_timestamp(),review_reason=v_reason,
      promoted_object_type=case when v_status='APPROVED' then btrim(p_promoted_object_type) else null end,
      promoted_object_id=case when v_status='APPROVED' then p_promoted_object_id else null end
  where id=v_candidate.id returning * into v_candidate;

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(v_candidate.case_id,'LEARNING_CANDIDATE_REVIEWED',v_actor,'OPERATOR','learning-reviewed:'||v_candidate.id::text,
    jsonb_build_object('learning_candidate_id',v_candidate.id,'status',v_candidate.status),
    jsonb_build_object('review_reason',v_reason,'promoted_object_type',v_candidate.promoted_object_type,
      'promoted_object_id',v_candidate.promoted_object_id,'canonical_object_creation_not_performed',true));

  return to_jsonb(v_candidate);
end;
$$;
revoke all on function public.whatsapp_review_learning_candidate(uuid,text,text,text,uuid) from public,anon,authenticated;
grant execute on function public.whatsapp_review_learning_candidate(uuid,text,text,text,uuid) to authenticated;


create or replace function public.whatsapp_get_case_learning_candidates(p_case_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_result jsonb;
begin
  if v_actor is null or not public.is_whatsapp_inbox_reader(v_actor) then raise exception 'WhatsApp inbox read permission required' using errcode='42501'; end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc,c.id desc),'[]'::jsonb)
  into v_result from public.whatsapp_learning_candidates c where c.case_id=p_case_id;
  return v_result;
end;
$$;
revoke all on function public.whatsapp_get_case_learning_candidates(uuid) from public,anon;
grant execute on function public.whatsapp_get_case_learning_candidates(uuid) to authenticated;


create or replace function public.whatsapp_record_legacy_retirement(
  p_capability_key text,
  p_legacy_surface text,
  p_disposition text,
  p_canonical_destination text,
  p_evidence jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_key text:=upper(btrim(coalesce(p_capability_key,'')));
  v_surface text:=btrim(coalesce(p_legacy_surface,''));
  v_disposition text:=upper(btrim(coalesce(p_disposition,'')));
  v_destination text:=btrim(coalesce(p_canonical_destination,''));
  v_previous public.whatsapp_legacy_capability_retirements%rowtype;
  v_result public.whatsapp_legacy_capability_retirements%rowtype;
  v_revision integer:=1;
begin
  if v_actor is null
     or not public.has_whatsapp_permission('wa.intake.assign')
     or not public.has_whatsapp_permission('wa.intake.close') then
    raise exception 'WhatsApp assignment and close authority required for legacy retirement sign-off' using errcode='42501';
  end if;
  if v_key='' or length(v_key)>120 or length(v_surface)<3 or length(v_surface)>500 or length(v_destination)<3 or length(v_destination)>500 then
    raise exception 'complete legacy retirement identity required';
  end if;
  if v_disposition not in ('RETIRED','MIGRATED_READ_ONLY','MIGRATED_SUGGESTION_ONLY','RETAINED_INGRESS_ONLY') then raise exception 'invalid legacy retirement disposition'; end if;
  if p_evidence is null or jsonb_typeof(p_evidence)<>'object' or p_evidence='{}'::jsonb then raise exception 'legacy retirement evidence required'; end if;

  select * into v_previous from public.whatsapp_legacy_capability_retirements
  where capability_key=v_key order by revision_number desc limit 1;
  if found then v_revision:=v_previous.revision_number+1; end if;

  insert into public.whatsapp_legacy_capability_retirements(
    capability_key,revision_number,supersedes_retirement_id,legacy_surface,disposition,
    canonical_destination,commercial_write_authority,evidence,verified_by,verified_at
  ) values (
    v_key,v_revision,case when v_revision>1 then v_previous.id else null end,
    v_surface,v_disposition,v_destination,false,p_evidence,v_actor,statement_timestamp()
  ) returning * into v_result;
  return to_jsonb(v_result);
end;
$$;
revoke all on function public.whatsapp_record_legacy_retirement(text,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.whatsapp_record_legacy_retirement(text,text,text,text,jsonb) to authenticated;


create or replace function public.whatsapp_get_legacy_retirements()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare v_actor uuid:=auth.uid(); v_result jsonb; begin
  if v_actor is null or not public.is_whatsapp_inbox_reader(v_actor) then raise exception 'WhatsApp inbox read permission required' using errcode='42501'; end if;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.capability_key,r.revision_number desc),'[]'::jsonb)
  into v_result from public.whatsapp_legacy_capability_retirements r;
  return v_result;
end;
$$;
revoke all on function public.whatsapp_get_legacy_retirements() from public,anon;
grant execute on function public.whatsapp_get_legacy_retirements() to authenticated;
