begin;
create table public.whatsapp_clarification_answer_evidence (
 id uuid primary key default gen_random_uuid(), clarification_request_id uuid not null references public.whatsapp_case_clarifications(id), communication_case_id uuid not null references public.whatsapp_communication_cases(id), answer_whatsapp_message_id uuid not null unique references public.whatsapp_messages(id), answer_inbound_message_id uuid not null unique references public.whatsapp_inbound_messages(id), answer_provider_message_id text not null unique, answer_packet_id uuid not null references public.whatsapp_message_packets(id), correlation_method text not null check(correlation_method in('PROVIDER_REPLY_REFERENCE','UNIQUE_OPEN_CLARIFICATION')), correlation_rule_version text not null default 'wa-cross-packet-lineage/v1', correlated_at timestamptz not null default statement_timestamp(), potential_order_id uuid references public.whatsapp_potential_orders(id), unique(clarification_request_id,answer_inbound_message_id)
);
alter table public.whatsapp_clarification_answer_evidence enable row level security;
revoke all on public.whatsapp_clarification_answer_evidence from public,anon,authenticated;
grant select,insert on public.whatsapp_clarification_answer_evidence to service_role;
create trigger whatsapp_clarification_answer_evidence_immutable before update or delete on public.whatsapp_clarification_answer_evidence for each row execute function public.wa1_audit_immutable();
create table public.whatsapp_potential_order_evidence_lineage (
 id uuid primary key default gen_random_uuid(), potential_order_id uuid not null references public.whatsapp_potential_orders(id), source_inbound_message_id uuid not null references public.whatsapp_inbound_messages(id), source_whatsapp_message_id uuid not null references public.whatsapp_messages(id), provider_message_id text not null, source_packet_id uuid not null references public.whatsapp_message_packets(id), communication_case_id uuid not null references public.whatsapp_communication_cases(id), clarification_answer_evidence_id uuid not null unique references public.whatsapp_clarification_answer_evidence(id), admission_rule_version text not null default 'wa-cross-packet-lineage/v1', admitted_at timestamptz not null default statement_timestamp(), unique(potential_order_id,source_inbound_message_id)
);
alter table public.whatsapp_potential_order_evidence_lineage enable row level security;
revoke all on public.whatsapp_potential_order_evidence_lineage from public,anon,authenticated;
grant select,insert on public.whatsapp_potential_order_evidence_lineage to service_role;
create trigger whatsapp_potential_order_evidence_lineage_immutable before update or delete on public.whatsapp_potential_order_evidence_lineage for each row execute function public.wa1_audit_immutable();
create or replace function public.whatsapp_potential_order_source_message_is_authorized(p_potential_order_id uuid,p_source_message_id uuid) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$ select exists(select 1 from public.whatsapp_potential_orders po where po.id=p_potential_order_id and (po.source_message_id=p_source_message_id or exists(select 1 from jsonb_array_elements(po.source_evidence)e where e->>'message_id'=p_source_message_id::text) or exists(select 1 from public.whatsapp_potential_order_evidence_lineage l where l.potential_order_id=po.id and l.source_inbound_message_id=p_source_message_id))) $$;
revoke all on function public.whatsapp_potential_order_source_message_is_authorized(uuid,uuid) from public,anon,authenticated;
grant execute on function public.whatsapp_potential_order_source_message_is_authorized(uuid,uuid) to service_role;
alter table public.whatsapp_communication_cases
  add column if not exists context_revision bigint not null default 0;

create table public.whatsapp_case_context_executions(
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  context_revision bigint not null check (context_revision > 0),
  answer_evidence_id uuid not null unique references public.whatsapp_clarification_answer_evidence(id) on delete restrict,
  packet_id uuid not null references public.whatsapp_message_packets(id) on delete restrict,
  created_at timestamptz not null default statement_timestamp(),
  unique(case_id,context_revision)
);
alter table public.whatsapp_case_context_executions enable row level security;
revoke all on public.whatsapp_case_context_executions from public,anon,authenticated;
grant select,insert on public.whatsapp_case_context_executions to service_role;
create trigger whatsapp_case_context_executions_immutable before update or delete on public.whatsapp_case_context_executions for each row execute function public.wa1_audit_immutable();
-- Case-context jobs deliberately reuse the packet-AI outbox lifecycle.  They
-- retain the original packet id for the canonical case, but carry a distinct
-- typed execution identity so a cross-packet answer cannot overwrite packet
-- evidence revision history.
alter table public.whatsapp_packet_ai_dispatch_jobs
  drop constraint if exists whatsapp_packet_ai_dispatch_jobs_packet_id_key;
alter table public.whatsapp_packet_ai_dispatch_jobs
  add column if not exists execution_kind text not null default 'PACKET'
    check (execution_kind in ('PACKET','CASE_CONTEXT')),
  add column if not exists case_id uuid references public.whatsapp_communication_cases(id) on delete restrict,
  add column if not exists context_revision bigint;
create unique index if not exists whatsapp_packet_ai_dispatch_packet_unique
  on public.whatsapp_packet_ai_dispatch_jobs(packet_id)
  where execution_kind='PACKET';
create unique index if not exists whatsapp_packet_ai_dispatch_case_context_unique
  on public.whatsapp_packet_ai_dispatch_jobs(case_id,context_revision)
  where execution_kind='CASE_CONTEXT';
alter table public.whatsapp_packet_ai_dispatch_jobs
  add constraint whatsapp_packet_ai_dispatch_execution_shape check (
    (execution_kind='PACKET' and case_id is null and context_revision is null)
    or (execution_kind='CASE_CONTEXT' and case_id is not null and context_revision is not null and context_revision > 0)
  );

create or replace function public.enqueue_whatsapp_case_context_ai_dispatch(
  p_case_id uuid,
  p_answer_evidence_id uuid
) returns public.whatsapp_packet_ai_dispatch_jobs
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_case public.whatsapp_communication_cases%rowtype;
  v_answer public.whatsapp_clarification_answer_evidence%rowtype;
  v_revision bigint;
  v_execution public.whatsapp_case_context_executions%rowtype;
  v_job public.whatsapp_packet_ai_dispatch_jobs%rowtype;
begin
  if coalesce(auth.jwt()->>'role','')<>'service_role' then
    raise exception 'trusted continuation required' using errcode='42501';
  end if;

  select * into v_answer
  from public.whatsapp_clarification_answer_evidence
  where id=p_answer_evidence_id and communication_case_id=p_case_id
  for share;
  if not found then raise exception 'trusted clarification answer evidence required'; end if;

  select * into v_case
  from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found or v_case.status in ('CLOSED','CANCELLED') then
    raise exception 'active communication case required';
  end if;

  select * into v_execution
  from public.whatsapp_case_context_executions
  where answer_evidence_id=v_answer.id;
  if found then
    select * into v_job from public.whatsapp_packet_ai_dispatch_jobs
    where execution_kind='CASE_CONTEXT'
      and case_id=v_execution.case_id
      and context_revision=v_execution.context_revision;
    if not found then raise exception 'case context execution lacks durable outbox job'; end if;
    return v_job;
  end if;

  update public.whatsapp_communication_cases
  set context_revision=context_revision+1,updated_at=statement_timestamp()
  where id=v_case.id
  returning context_revision into v_revision;

  insert into public.whatsapp_case_context_executions(
    case_id,context_revision,answer_evidence_id,packet_id
  ) values (
    v_case.id,v_revision,v_answer.id,v_case.packet_id
  ) returning * into v_execution;

  insert into public.whatsapp_packet_ai_dispatch_jobs(
    packet_id,packet_revision,logical_dispatch_key,execution_kind,case_id,context_revision
  ) values (
    v_case.packet_id,v_revision,
    'case:'||v_case.id::text||':context-revision:'||v_revision::text,
    'CASE_CONTEXT',v_case.id,v_revision
  ) returning * into v_job;
  return v_job;
end $$;

revoke all on function public.enqueue_whatsapp_case_context_ai_dispatch(uuid,uuid) from public,anon,authenticated;
grant execute on function public.enqueue_whatsapp_case_context_ai_dispatch(uuid,uuid) to service_role;

create or replace function public.whatsapp_correlate_clarification_answer(
  p_answer_whatsapp_message_id uuid,
  p_reply_reference text default null
) returns public.whatsapp_clarification_answer_evidence
language plpgsql security definer set search_path=pg_catalog,public as $$
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
 if v_inbound_match_count<>1 or v_inbound_message_id is null then
   raise exception 'clarification answer provider_message_id must resolve to exactly one inbound message';
 end if;
 select * into v_inbound from public.whatsapp_inbound_messages where id=v_inbound_message_id;

 -- A provider context/reply reference is the primary authority.  Fallback is
 -- permitted only without a usable reference and must be exactly one candidate.
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
 if v_candidate_count<>1 then raise exception 'clarification correlation is not unique'; end if;
 select * into v_clarification from public.whatsapp_case_clarifications where id=v_clarification_id for share;
 if v_clarification.status<>'OPEN' then raise exception 'clarification is not open'; end if;

 -- This is the sole case-to-potential-order bridge.  A NULL means a non-order
 -- case (or no safe commercial relationship), and must not manufacture lineage.
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
   return v_answer_evidence;
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
revoke all on function public.whatsapp_correlate_clarification_answer(uuid,text) from public,anon,authenticated;
grant execute on function public.whatsapp_correlate_clarification_answer(uuid,text) to service_role;

create or replace function public.record_whatsapp_order_field_evidence(
 p_potential_order_id uuid,p_field_key text,p_source_message_id uuid,p_evidence_key text,p_candidate_value jsonb,
 p_extraction_state text,p_confidence numeric default null,p_source_excerpt text default null,p_metadata jsonb default '{}',p_is_required boolean default true
) returns public.whatsapp_order_field_resolutions
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_po public.whatsapp_potential_orders%rowtype; v_evidence public.whatsapp_order_field_evidence%rowtype; v_existing public.whatsapp_order_field_resolutions%rowtype; v_result public.whatsapp_order_field_resolutions%rowtype; v_state text; v_question text;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' and (auth.uid() is null or not public.has_whatsapp_permission('wa.intake.triage')) then raise exception 'WA3_TRIAGE_REQUIRED' using errcode='P0001'; end if;
 if p_field_key not in('client_identity','product','quantity','unit_packaging','delivery_address','payment_terms','moq_carton') then raise exception 'WA3_INVALID_FIELD'; end if;
 if nullif(btrim(p_evidence_key),'') is null then raise exception 'WA3_EVIDENCE_KEY_REQUIRED'; end if;
 select * into v_po from public.whatsapp_potential_orders where id=p_potential_order_id for update;
 if not found or v_po.disposition<>'ACTIVE_PENDING' then raise exception 'WA3_ACTIVE_POTENTIAL_ORDER_REQUIRED'; end if;
 if not public.whatsapp_potential_order_source_message_is_authorized(p_potential_order_id,p_source_message_id) then raise exception 'WA3_SOURCE_NOT_LINKED'; end if;
 insert into public.whatsapp_order_field_evidence(potential_order_id,field_key,source_message_id,evidence_key,candidate_value,extraction_state,confidence,source_excerpt,metadata,recorded_by)
 values(p_potential_order_id,p_field_key,p_source_message_id,btrim(p_evidence_key),p_candidate_value,p_extraction_state,p_confidence,p_source_excerpt,coalesce(p_metadata,'{}'),auth.uid())
 on conflict(potential_order_id,field_key,evidence_key) do nothing returning * into v_evidence;
 if not found then select * into v_evidence from public.whatsapp_order_field_evidence where potential_order_id=p_potential_order_id and field_key=p_field_key and evidence_key=btrim(p_evidence_key); end if;
 select * into v_existing from public.whatsapp_order_field_resolutions where potential_order_id=p_potential_order_id and field_key=p_field_key for update;
 -- Replays use the first immutable payload stored under the idempotency key.
 v_state:=case
  when v_evidence.extraction_state='not_applicable' and not p_is_required then 'not_applicable'
  when v_evidence.extraction_state='operator_confirmation' and auth.uid() is not null and v_evidence.candidate_value is not null then 'operator_confirmed'
  when v_evidence.extraction_state='historical_reference' then 'awaiting_clarification'
  when v_evidence.extraction_state in('ambiguous','low_confidence') then 'ambiguous'
  when v_evidence.extraction_state in('ai_failure','unresolved') or v_evidence.candidate_value is null then 'unresolved'
  when coalesce(v_evidence.confidence,1)<0.70 then 'ambiguous'
  when found and v_existing.resolved_value is not null and v_existing.resolved_value<>v_evidence.candidate_value then 'conflicting'
  else 'resolved' end;
 perform set_config('app.wa3_governed_mutation','on',true);
 insert into public.whatsapp_order_field_resolutions(potential_order_id,field_key,resolution_state,is_required,resolved_value,resolved_evidence_id,resolution_reason,resolved_by,resolved_at)
 values(p_potential_order_id,p_field_key,v_state,p_is_required,case when v_state in('resolved','operator_confirmed') then v_evidence.candidate_value end,case when v_state in('resolved','operator_confirmed') then v_evidence.id end,case when v_state='not_applicable' then coalesce(v_evidence.metadata->>'reason','explicitly not applicable') else v_evidence.extraction_state end,case when v_state in('operator_confirmed','not_applicable') then auth.uid() end,case when v_state in('resolved','operator_confirmed') then now() end)
 on conflict(potential_order_id,field_key) do update set resolution_state=excluded.resolution_state,is_required=excluded.is_required,resolved_value=excluded.resolved_value,resolved_evidence_id=excluded.resolved_evidence_id,resolution_reason=excluded.resolution_reason,resolved_by=excluded.resolved_by,resolved_at=excluded.resolved_at,updated_at=now()
 returning * into v_result;
 if v_state in('unresolved','ambiguous','conflicting','awaiting_clarification') then
  v_question:=public.wa3_clarification_question(p_field_key);
  insert into public.whatsapp_order_clarification_tasks(potential_order_id,field_key,idempotency_key,question,owner_id,created_by)
  values(p_potential_order_id,p_field_key,'field:'||p_field_key||':evidence:'||v_evidence.id,v_question,v_po.owner_id,auth.uid()) on conflict do nothing;
  perform set_config('app.wa1_governed_mutation','on',true);
  update public.whatsapp_potential_orders set state='AWAITING_CLARIFICATION',next_action='CLARIFY_'||upper(p_field_key),next_action_due_at=least(next_action_due_at,now()+interval '30 minutes'),updated_at=now() where id=p_potential_order_id;
  insert into public.whatsapp_potential_order_audit_log(potential_order_id,action,from_state,to_state,actor_id,evidence) values(p_potential_order_id,'FIELD_CLARIFICATION_REQUIRED',v_po.state,'AWAITING_CLARIFICATION',auth.uid(),jsonb_build_object('field_key',p_field_key,'evidence_id',v_evidence.id,'resolution_state',v_state));
  perform set_config('app.wa1_governed_mutation','off',true);
 end if;
 perform set_config('app.wa3_governed_mutation','off',true);
 return v_result;
exception when others then perform set_config('app.wa3_governed_mutation','off',true); perform set_config('app.wa1_governed_mutation','off',true); raise;
end $$;

revoke all on function public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean) from public,anon;
grant execute on function public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean) to authenticated,service_role;

create or replace function public.enqueue_whatsapp_packet_ai_dispatch()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_revision bigint; v_key text;
begin
  if lower(new.direction) <> 'inbound'
     or new.packet_id is null
     or (tg_op = 'UPDATE' and new.packet_id is not distinct from old.packet_id) then
    return new;
  end if;
  update public.whatsapp_message_packets
  set ai_dispatch_revision = ai_dispatch_revision + 1, updated_at = statement_timestamp()
  where id = new.packet_id returning ai_dispatch_revision into v_revision;
  v_key := 'packet:' || new.packet_id::text || ':revision:' || v_revision::text;
  insert into public.whatsapp_packet_ai_dispatch_jobs(
    packet_id,packet_revision,logical_dispatch_key,execution_kind
  ) values(new.packet_id,v_revision,v_key,'PACKET')
  on conflict (packet_id) where (execution_kind='PACKET') do update set
    packet_revision=excluded.packet_revision, logical_dispatch_key=excluded.logical_dispatch_key,
    state=case when public.whatsapp_packet_ai_dispatch_jobs.state='LEASED' then 'LEASED' else 'QUEUED' end,
    next_retry_at=statement_timestamp(), last_error_code=null, last_error_detail=null,
    completed_at=null, updated_at=statement_timestamp();
  return new;
end $$;

create or replace function public.assert_whatsapp_packet_ai_dispatch_lease(
  p_job_id uuid, p_lease_token uuid, p_packet_revision bigint
) returns boolean language sql security definer set search_path = pg_catalog, public as $$
  select exists(
    select 1 from public.whatsapp_packet_ai_dispatch_jobs j
    where j.id=p_job_id and j.state='LEASED' and j.lease_token=p_lease_token
      and j.packet_revision=p_packet_revision and j.lease_expires_at > statement_timestamp()
      and (
        (j.execution_kind='PACKET')
        or (j.execution_kind='CASE_CONTEXT' and exists(
          select 1 from public.whatsapp_communication_cases c
          where c.id=j.case_id and c.context_revision=j.context_revision
        ))
      )
  );
$$;

create or replace function public.complete_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid, p_lease_token uuid, p_packet_revision bigint
) returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_updated integer;
begin
  update public.whatsapp_packet_ai_dispatch_jobs j
  set state='COMPLETED', claimed_at=null, lease_expires_at=null, lease_token=null,
      completed_at=statement_timestamp(), last_error_code=null, last_error_detail=null,
      updated_at=statement_timestamp()
  where j.id=p_job_id and j.state='LEASED' and j.lease_token=p_lease_token
    and j.packet_revision=p_packet_revision and j.lease_expires_at > statement_timestamp()
    and (j.execution_kind='PACKET' or exists(
      select 1 from public.whatsapp_communication_cases c
      where c.id=j.case_id and c.context_revision=j.context_revision
    ));
  get diagnostics v_updated=row_count;
  return v_updated=1;
end $$;

create or replace function public.retry_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid,p_lease_token uuid,p_packet_revision bigint,
  p_error_code text,p_error_detail text default null,p_knowledge_authority_failure boolean default false
) returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_updated integer; v_code text:=left(btrim(coalesce(p_error_code,'')),120); v_detail text:=left(btrim(coalesce(p_error_detail,'')),500);
begin
  if v_code='' then raise exception 'error code required' using errcode='22023'; end if;
  update public.whatsapp_packet_ai_dispatch_jobs j
  set state=case when p_knowledge_authority_failure then 'BLOCKED_KNOWLEDGE_AUTHORITY' else 'RETRY' end,
      claimed_at=null,lease_expires_at=null,lease_token=null,last_error_code=v_code,
      last_error_detail=nullif(v_detail,''),
      next_retry_at=statement_timestamp()+make_interval(secs=>least(900,15*power(2,least(j.attempt_count,5))::integer)),
      updated_at=statement_timestamp()
  where j.id=p_job_id and j.state='LEASED' and j.lease_token=p_lease_token
    and j.packet_revision=p_packet_revision
    and (j.execution_kind='PACKET' or exists(
      select 1 from public.whatsapp_communication_cases c
      where c.id=j.case_id and c.context_revision=j.context_revision
    ));
  get diagnostics v_updated=row_count;
  return v_updated=1;
end $$;

create or replace function public.release_superseded_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid,p_lease_token uuid,p_claimed_packet_revision bigint
) returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_updated integer;
begin
  update public.whatsapp_packet_ai_dispatch_jobs j
  set state=case when j.execution_kind='CASE_CONTEXT' then 'COMPLETED' else 'QUEUED' end,
      claimed_at=null,lease_expires_at=null,lease_token=null,
      completed_at=case when j.execution_kind='CASE_CONTEXT' then statement_timestamp() else null end,
      next_retry_at=statement_timestamp(),updated_at=statement_timestamp()
  where j.id=p_job_id and j.state='LEASED' and j.lease_token=p_lease_token
    and (
      j.packet_revision<>p_claimed_packet_revision
      or (j.execution_kind='CASE_CONTEXT' and not exists(
        select 1 from public.whatsapp_communication_cases c
        where c.id=j.case_id and c.context_revision=j.context_revision
      ))
    );
  get diagnostics v_updated=row_count;
  return v_updated=1;
end $$;

create or replace function public.whatsapp_case_context_messages(p_case_id uuid)
returns table(
  provider_message_id text,
  content text,
  message_type text,
  media_url text,
  message_timestamp timestamptz,
  packet_sequence integer
)
language sql stable security definer set search_path=pg_catalog,public as $$
  with governed_case as (
    select c.id,c.packet_id from public.whatsapp_communication_cases c where c.id=p_case_id
  ), original_evidence as (
    select wm.provider_message_id::text,wm.content,wm.message_type::text,wm.media_url,
      wm.message_timestamp::timestamptz,wm.packet_sequence
    from governed_case c
    join public.whatsapp_messages wm on wm.packet_id=c.packet_id
    where lower(wm.direction)='inbound'
  ), approved_answers as (
    select wm.provider_message_id::text,wm.content,wm.message_type::text,wm.media_url,
      wm.message_timestamp::timestamptz,wm.packet_sequence
    from public.whatsapp_clarification_answer_evidence ae
    join public.whatsapp_messages wm on wm.id=ae.answer_whatsapp_message_id
    where ae.communication_case_id=p_case_id and lower(wm.direction)='inbound'
  )
  select provider_message_id,content,message_type,media_url,message_timestamp,packet_sequence
  from (
    select distinct on (provider_message_id)
      provider_message_id,content,message_type,media_url,message_timestamp,packet_sequence
    from (select * from original_evidence union all select * from approved_answers) evidence
    where nullif(btrim(provider_message_id),'') is not null
    order by provider_message_id,message_timestamp,packet_sequence
  ) deduplicated
  order by message_timestamp,packet_sequence,provider_message_id
  limit 17;
$$;
revoke all on function public.whatsapp_case_context_messages(uuid) from public,anon,authenticated;
grant execute on function public.whatsapp_case_context_messages(uuid) to service_role;
commit;
