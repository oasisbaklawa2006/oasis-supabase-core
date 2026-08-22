-- PR #102 final hardening: atomic lease writes, knowledge governance closure,
-- clarification replay self-healing, and governed interpretation persistence.

begin;

alter table public.whatsapp_packet_ai_interpretations
  add column if not exists knowledge_snapshot_content_checksum text;

comment on column public.whatsapp_packet_ai_interpretations.knowledge_snapshot_content_checksum is
  'SHA-256 checksum of the exact governed knowledge publication consumed by this interpretation.';

create or replace function public.whatsapp_guard_intelligence_snapshot_mutation()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if tg_op = 'INSERT' then
    if new.lifecycle = 'ACTIVE'
       and current_setting('app.whatsapp_knowledge_activation', true) is distinct from 'on' then
      raise exception 'knowledge activation must use governed activation RPC' using errcode = '42501';
    end if;
    return new;
  end if;

  if (new.lifecycle = 'ACTIVE' or old.lifecycle = 'ACTIVE')
     and current_setting('app.whatsapp_knowledge_activation', true) is distinct from 'on' then
    raise exception 'knowledge activation must use governed activation RPC' using errcode = '42501';
  end if;
  if old.lifecycle <> 'DRAFT' and (
    new.schema_version is distinct from old.schema_version
    or new.source_catalogue_version_ids is distinct from old.source_catalogue_version_ids
    or new.knowledge is distinct from old.knowledge
    or new.content_checksum is distinct from old.content_checksum
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
  ) then
    raise exception 'approved intelligence publication content is immutable' using errcode = '55000';
  end if;
  return new;
end $$;

drop trigger if exists whatsapp_intelligence_snapshot_content_immutable
  on public.whatsapp_intelligence_knowledge_snapshots;
create trigger whatsapp_intelligence_snapshot_content_immutable
before insert or update on public.whatsapp_intelligence_knowledge_snapshots
for each row execute function public.whatsapp_guard_intelligence_snapshot_mutation();

create or replace function public.whatsapp_activate_intelligence_knowledge_snapshot(
  p_snapshot_id uuid
)
returns public.whatsapp_intelligence_knowledge_snapshots
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_target public.whatsapp_intelligence_knowledge_snapshots%rowtype;
  v_previous public.whatsapp_intelligence_knowledge_snapshots%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended('whatsapp_intelligence_knowledge_snapshot_activation', 0));
  select * into v_target from public.whatsapp_intelligence_knowledge_snapshots
  where id = p_snapshot_id for update;
  if not found then raise exception 'knowledge publication not found' using errcode = 'P0002'; end if;
  if v_target.lifecycle not in ('APPROVED','ACTIVE') then
    raise exception 'only approved knowledge can become active' using errcode = '55000';
  end if;
  if v_target.lifecycle = 'ACTIVE' then
    perform set_config('app.whatsapp_knowledge_activation', 'off', true);
    return v_target;
  end if;

  select * into v_previous from public.whatsapp_intelligence_knowledge_snapshots
  where lifecycle = 'ACTIVE' for update;
  perform set_config('app.whatsapp_knowledge_activation', 'on', true);
  if v_previous.id is not null then
    update public.whatsapp_intelligence_knowledge_snapshots
    set lifecycle = 'SUPERSEDED', superseded_at = statement_timestamp(), superseded_by = v_target.id
    where id = v_previous.id;
  end if;
  update public.whatsapp_intelligence_knowledge_snapshots
  set lifecycle = 'ACTIVE',
      published_at = coalesce(published_at, statement_timestamp()),
      activated_at = statement_timestamp(),
      superseded_at = null,
      superseded_by = null
  where id = v_target.id
  returning * into v_target;
  perform set_config('app.whatsapp_knowledge_activation', 'off', true);
  return v_target;
exception when others then
  perform set_config('app.whatsapp_knowledge_activation', 'off', true);
  raise;
end $$;

create or replace function public.whatsapp_require_packet_ai_dispatch_lease(
  p_job_id uuid,
  p_lease_token uuid,
  p_packet_revision bigint
)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not coalesce(public.assert_whatsapp_packet_ai_dispatch_lease(
    p_job_id, p_lease_token, p_packet_revision
  ), false) then
    raise exception 'dispatch lease invalid or superseded' using errcode = '55000';
  end if;
end $$;

revoke all on function public.whatsapp_require_packet_ai_dispatch_lease(uuid,uuid,bigint)
  from public, anon, authenticated;
grant execute on function public.whatsapp_require_packet_ai_dispatch_lease(uuid,uuid,bigint)
  to service_role;

create or replace function public.whatsapp_persist_packet_ai_interpretation_governed(
  p_packet_id uuid,
  p_content_fingerprint text,
  p_provider_message_ids text[],
  p_interpretation jsonb,
  p_model_version text,
  p_knowledge_snapshot_id uuid,
  p_knowledge_snapshot_schema_version text,
  p_knowledge_snapshot_content_checksum text,
  p_interpretation_schema_version text,
  p_prompt_policy_version text,
  p_resolver_policy_version text,
  p_job_id uuid default null,
  p_lease_token uuid default null,
  p_packet_revision bigint default null
)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_active public.whatsapp_intelligence_knowledge_snapshots%rowtype;
  v_id uuid;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  if p_job_id is not null then
    perform public.whatsapp_require_packet_ai_dispatch_lease(
      p_job_id, p_lease_token, p_packet_revision
    );
  end if;

  select * into v_active from public.whatsapp_active_intelligence_knowledge_snapshot();
  if v_active.id is null then
    raise exception 'no actively governed intelligence knowledge snapshot' using errcode = '55000';
  end if;
  if v_active.id is distinct from p_knowledge_snapshot_id
     or v_active.schema_version is distinct from p_knowledge_snapshot_schema_version
     or v_active.content_checksum is distinct from p_knowledge_snapshot_content_checksum then
    raise exception 'knowledge snapshot provenance does not match active authority' using errcode = '55000';
  end if;

  insert into public.whatsapp_packet_ai_interpretations (
    packet_id,
    content_fingerprint,
    provider_message_ids,
    interpretation,
    model_version,
    knowledge_snapshot_id,
    knowledge_snapshot_schema_version,
    knowledge_snapshot_content_checksum,
    interpretation_schema_version,
    prompt_policy_version,
    resolver_policy_version
  ) values (
    p_packet_id,
    p_content_fingerprint,
    p_provider_message_ids,
    p_interpretation,
    p_model_version,
    p_knowledge_snapshot_id,
    p_knowledge_snapshot_schema_version,
    p_knowledge_snapshot_content_checksum,
    p_interpretation_schema_version,
    p_prompt_policy_version,
    p_resolver_policy_version
  )
  on conflict (packet_id, content_fingerprint) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id
    from public.whatsapp_packet_ai_interpretations
    where packet_id = p_packet_id
      and content_fingerprint = p_content_fingerprint;
  end if;

  if v_id is null then
    raise exception 'interpretation canonical row could not be resolved' using errcode = '55000';
  end if;

  return v_id;
end $$;

revoke all on function public.whatsapp_persist_packet_ai_interpretation_governed(
  uuid,text,text[],jsonb,text,uuid,text,text,text,text,text,uuid,uuid,bigint
) from public, anon, authenticated;
grant execute on function public.whatsapp_persist_packet_ai_interpretation_governed(
  uuid,text,text[],jsonb,text,uuid,text,text,text,text,text,uuid,uuid,bigint
) to service_role;

drop function if exists public.whatsapp_materialize_packet_ai_case(uuid, uuid);

create or replace function public.whatsapp_materialize_packet_ai_case(
  p_packet_id uuid,
  p_interpretation_id uuid,
  p_job_id uuid default null,
  p_lease_token uuid default null,
  p_packet_revision bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_role text := coalesce(auth.jwt() ->> 'role', '');
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_ai public.whatsapp_packet_ai_interpretations%rowtype;
  v_conclusion jsonb;
  v_intent text;
  v_case_type text;
  v_case public.whatsapp_communication_cases%rowtype;
  v_recommended_action text;
  v_primary_department text;
  v_contributors jsonb;
  v_reply_clearance text;
  v_draft_reply text;
  v_ambiguity_count integer := 0;
  v_event_key text;
begin
  if v_role <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  if p_job_id is not null then
    perform public.whatsapp_require_packet_ai_dispatch_lease(
      p_job_id, p_lease_token, p_packet_revision
    );
  end if;

  select * into v_packet
  from public.whatsapp_message_packets
  where id = p_packet_id;

  if not found then
    raise exception 'WhatsApp packet not found';
  end if;

  select * into v_ai
  from public.whatsapp_packet_ai_interpretations
  where id = p_interpretation_id
    and packet_id = p_packet_id;

  if not found then
    raise exception 'packet AI interpretation not found for packet';
  end if;

  select * into v_contact
  from public.whatsapp_contacts
  where id = v_packet.contact_id;

  if not found then
    raise exception 'WhatsApp packet contact not found';
  end if;

  v_conclusion := case
    when jsonb_typeof(v_ai.interpretation -> 'conclusion') = 'object'
      then v_ai.interpretation -> 'conclusion'
    else '{}'::jsonb
  end;

  v_intent := upper(coalesce(nullif(btrim(v_conclusion ->> 'intent'), ''), 'UNCLEAR'));
  v_case_type := case v_intent
    when 'NEW_ORDER' then 'ORDER'
    when 'ORDER' then 'ORDER'
    when 'AMENDMENT' then 'ORDER_CHANGE'
    when 'ORDER_CHANGE' then 'ORDER_CHANGE'
    when 'CANCELLATION' then 'CANCELLATION'
    when 'ENQUIRY' then 'ENQUIRY'
    when 'COMPLAINT' then 'COMPLAINT'
    when 'PAYMENT_ADVICE' then 'PAYMENT_ADVICE'
    when 'ACCOUNT_QUERY' then 'ACCOUNT_QUERY'
    when 'FINANCE' then 'ACCOUNT_QUERY'
    when 'DELIVERY_QUERY' then 'DISPATCH'
    when 'DISPATCH' then 'DISPATCH'
    when 'SPECIFICATION_QUERY' then 'SPECIFICATION'
    when 'SPECIFICATION' then 'SPECIFICATION'
    else 'UNCLASSIFIED'
  end;

  v_recommended_action := nullif(btrim(coalesce(v_conclusion ->> 'recommended_action', '')), '');
  v_primary_department := nullif(upper(btrim(coalesce(v_conclusion ->> 'primary_department', ''))), '');
  v_contributors := case
    when jsonb_typeof(v_conclusion -> 'contributor_departments') = 'array'
      then v_conclusion -> 'contributor_departments'
    else '[]'::jsonb
  end;
  v_reply_clearance := nullif(upper(btrim(coalesce(v_conclusion ->> 'reply_clearance', ''))), '');
  v_draft_reply := nullif(btrim(coalesce(v_conclusion ->> 'draft_reply', '')), '');
  v_ambiguity_count := case
    when jsonb_typeof(v_conclusion -> 'ambiguities') = 'array'
      then jsonb_array_length(v_conclusion -> 'ambiguities')
    else 0
  end;

  insert into public.whatsapp_communication_cases (
    packet_id,
    case_type,
    status,
    next_action,
    source_channel,
    rule_version
  ) values (
    p_packet_id,
    v_case_type,
    'NEEDS_IDENTITY',
    v_recommended_action,
    'WHATSAPP',
    'packet-ai-b2b-v1'
  )
  on conflict (packet_id) do update
  set case_type = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION')
          then excluded.case_type
        else public.whatsapp_communication_cases.case_type
      end,
      next_action = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION')
          then excluded.next_action
        else public.whatsapp_communication_cases.next_action
      end,
      rule_version = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION')
          then excluded.rule_version
        else public.whatsapp_communication_cases.rule_version
      end,
      updated_at = statement_timestamp()
  returning * into v_case;

  insert into public.whatsapp_case_identities (
    case_id,
    identity_role,
    party_type,
    party_id,
    display_label,
    phone_e164,
    resolution_status,
    confidence,
    evidence
  ) values (
    v_case.id,
    'SUBMITTING_SENDER',
    'CONTACT',
    v_contact.id,
    coalesce(nullif(v_contact.customer_name, ''), nullif(v_contact.company_name, ''), v_contact.phone_number),
    v_contact.phone_number,
    'SUGGESTED',
    1.0,
    jsonb_build_array(jsonb_build_object(
      'source', 'WHATSAPP_PACKET',
      'packet_id', p_packet_id,
      'contact_id', v_contact.id
    ))
  )
  on conflict (case_id, identity_role) do update
  set party_type = excluded.party_type,
      party_id = excluded.party_id,
      display_label = excluded.display_label,
      phone_e164 = excluded.phone_e164,
      confidence = excluded.confidence,
      evidence = excluded.evidence
  where public.whatsapp_case_identities.resolution_status <> 'CONFIRMED';

  v_event_key := 'packet-ai:' || p_interpretation_id::text;

  insert into public.whatsapp_case_events (
    case_id,
    event_type,
    actor_id,
    actor_type,
    correlation_key,
    resulting_state,
    metadata
  ) values (
    v_case.id,
    'AI_CONCLUSION_READY',
    null,
    'SYSTEM',
    v_event_key,
    jsonb_build_object(
      'case_type', v_case_type,
      'case_status', v_case.status,
      'human_decision_required', true
    ),
    jsonb_build_object(
      'packet_id', p_packet_id,
      'packet_ai_interpretation_id', p_interpretation_id,
      'content_fingerprint', v_ai.content_fingerprint,
      'model_version', v_ai.model_version,
      'intent', v_intent,
      'summary', coalesce(v_conclusion ->> 'summary', ''),
      'confidence', v_ai.interpretation -> 'confidence',
      'ambiguity_count', v_ambiguity_count,
      'recommended_action', v_recommended_action,
      'primary_department', v_primary_department,
      'contributor_departments', v_contributors,
      'reply_clearance', v_reply_clearance,
      'draft_reply', v_draft_reply,
      'human_review_required', true,
      'conclusion', v_conclusion
    )
  )
  on conflict (case_id, correlation_key) do nothing;

  return jsonb_build_object(
    'case_id', v_case.id,
    'packet_id', p_packet_id,
    'case_type', v_case.case_type,
    'status', v_case.status,
    'accountability_status', v_case.accountability_status,
    'ai_event_correlation_key', v_event_key,
    'human_decision_required', true
  );
end;
$$;

comment on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint) is
  'Service-role-only bridge from append-only packet AI interpretation to the governed B2B communication-case programme. Optional lease parameters atomically validate dispatch authority before durable case effects.';

revoke all on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint)
  from public, anon, authenticated;
grant execute on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint)
  to service_role;

create or replace function public.whatsapp_correlate_clarification_answer(
  p_answer_whatsapp_message_id uuid,
  p_reply_reference text default null
) returns public.whatsapp_clarification_answer_evidence
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
 v_answer public.whatsapp_messages%rowtype;
 v_inbound_match_count bigint;
 v_inbound_message_id uuid;
 v_inbound public.whatsapp_inbound_messages%rowtype;
 v_candidate_count bigint;
 v_clarification_id uuid;
 v_clarification public.whatsapp_case_clarifications%rowtype;
 v_potential_order_id uuid;
 v_answer_evidence public.whatsapp_clarification_answer_evidence%rowtype;
 v_inserted_answer_evidence_id uuid;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then
   raise exception 'trusted continuation required' using errcode='42501';
 end if;
 select * into v_answer from public.whatsapp_messages
 where id=p_answer_whatsapp_message_id and lower(direction)='inbound' for update;
 if not found or nullif(btrim(v_answer.provider_message_id),'') is null or v_answer.packet_id is null then
   raise exception 'inbound provider evidence required';
 end if;
 SELECT count(*), min(id)
 INTO v_inbound_match_count, v_inbound_message_id
 FROM public.whatsapp_inbound_messages
 WHERE provider_message_id=v_answer.provider_message_id;
 if v_inbound_match_count = 0 then
   raise exception 'clarification answer provider_message_id unresolved' using errcode='P0001';
 end if;
 if v_inbound_match_count > 1 or v_inbound_message_id is null then
   raise exception 'clarification answer provider_message_id ambiguous' using errcode='P0001';
 end if;
 select * into v_inbound from public.whatsapp_inbound_messages where id=v_inbound_message_id;

 if nullif(btrim(p_reply_reference),'') is not null then
   select count(*),min(q.id) into v_candidate_count,v_clarification_id
   from public.whatsapp_case_clarifications q
   join public.whatsapp_communication_cases k on k.id=q.case_id
   join public.whatsapp_message_packets p on p.id=k.packet_id
   join public.whatsapp_operator_reply_outbox o on o.id=q.source_outbound_message_id
   where q.status='OPEN' and k.status='AWAITING_CUSTOMER'
     and p.contact_id=v_answer.contact_id
     and o.provider_message_id=btrim(p_reply_reference)
     and q.asked_at<=v_answer.created_at;
 else
   select count(*),min(q.id) into v_candidate_count,v_clarification_id
   from public.whatsapp_case_clarifications q
   join public.whatsapp_communication_cases k on k.id=q.case_id
   join public.whatsapp_message_packets p on p.id=k.packet_id
   where q.status='OPEN' and k.status='AWAITING_CUSTOMER'
     and p.contact_id=v_answer.contact_id
     and q.asked_at<=v_answer.created_at;
 end if;
 if v_candidate_count = 0 then
   raise exception 'no compatible open clarification' using errcode='P0001';
 end if;
 if v_candidate_count > 1 then
   raise exception 'multiple compatible clarifications' using errcode='P0001';
 end if;
 select * into v_clarification from public.whatsapp_case_clarifications where id=v_clarification_id for share;
 if v_clarification.status<>'OPEN' then raise exception 'clarification is not open'; end if;

 if exists (
   select 1 from public.whatsapp_clarification_answer_evidence
   where answer_inbound_message_id = v_inbound.id
     and answer_whatsapp_message_id is distinct from v_answer.id
 ) then
   raise exception 'clarification answer inbound identity already consumed' using errcode='23505';
 end if;
 if exists (
   select 1 from public.whatsapp_clarification_answer_evidence
   where answer_provider_message_id = v_answer.provider_message_id
     and answer_whatsapp_message_id is distinct from v_answer.id
 ) then
   raise exception 'clarification answer provider identity already consumed' using errcode='23505';
 end if;

 v_potential_order_id:=public.whatsapp_case_potential_order_id(v_clarification.case_id);
 insert into public.whatsapp_clarification_answer_evidence(
   clarification_request_id,communication_case_id,answer_whatsapp_message_id,
   answer_inbound_message_id,answer_provider_message_id,answer_packet_id,
   correlation_method,potential_order_id
 ) values (
   v_clarification.id,v_clarification.case_id,v_answer.id,v_inbound.id,
   v_answer.provider_message_id,v_answer.packet_id,
   case when nullif(btrim(p_reply_reference),'') is null then 'UNIQUE_OPEN_CLARIFICATION' else 'PROVIDER_REPLY_REFERENCE' end,
   v_potential_order_id
 ) on conflict(answer_whatsapp_message_id) do nothing
 returning id into v_inserted_answer_evidence_id;
 select * into v_answer_evidence from public.whatsapp_clarification_answer_evidence
 where answer_whatsapp_message_id=v_answer.id;
 if not found then raise exception 'clarification answer evidence canonical row could not be resolved'; end if;
 if v_inserted_answer_evidence_id is null then
   if v_answer_evidence.clarification_request_id<>v_clarification.id
      or v_answer_evidence.communication_case_id<>v_clarification.case_id
      or v_answer_evidence.answer_inbound_message_id<>v_inbound.id then
     raise exception 'clarification answer evidence already consumed incompatibly';
   end if;
   -- Replay must re-resolve the governed bridge: a potential order may have
   -- become available after the original evidence correlation.
   v_potential_order_id:=public.whatsapp_case_potential_order_id(v_clarification.case_id);
 end if;

 if v_potential_order_id is not null then
   insert into public.whatsapp_potential_order_evidence_lineage(
     potential_order_id,source_inbound_message_id,source_whatsapp_message_id,
     provider_message_id,source_packet_id,communication_case_id,
     clarification_answer_evidence_id
   ) values (
     v_potential_order_id,v_inbound.id,v_answer.id,v_answer.provider_message_id,
     v_answer.packet_id,v_clarification.case_id,v_answer_evidence.id
   ) on conflict(potential_order_id,source_inbound_message_id) do nothing;
   if not exists(select 1 from public.whatsapp_potential_order_evidence_lineage
                 where potential_order_id=v_potential_order_id
                   and source_inbound_message_id=v_inbound.id
                   and clarification_answer_evidence_id=v_answer_evidence.id) then
     raise exception 'continuation evidence already admitted incompatibly';
   end if;
 end if;
 perform public.enqueue_whatsapp_case_context_ai_dispatch(v_clarification.case_id,v_answer_evidence.id);
 return v_answer_evidence;
end $$;

comment on function public.whatsapp_persist_packet_ai_interpretation_governed(
  uuid,text,text[],jsonb,text,uuid,text,text,text,text,text,uuid,uuid,bigint
) is 'Atomically validates dispatch lease authority and active knowledge provenance before append-only interpretation persistence.';

commit;
