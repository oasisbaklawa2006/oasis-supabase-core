-- WA-4: deterministic multi-message / multimodal commercial evidence.
-- Roll forward only. The new ledger is additive; source rows and WA-1 outcomes are
-- never deleted. A rollback consists of disabling callers, not destructive DDL.

create table public.whatsapp_commercial_packets (
  id uuid primary key default gen_random_uuid(),
  potential_order_id uuid not null unique references public.whatsapp_potential_orders(id) on delete restrict,
  sender_key text not null,
  conversation_key text not null,
  status text not null default 'OPEN' check(status in ('OPEN','AWAITING_MEDIA','FAILED_MEDIA','SPLIT','MERGED','CLOSED')),
  processing_state text not null default 'PENDING' check(processing_state in ('PENDING','PROCESSING','READY','FAILED','HUMAN_REVIEW')),
  first_received_at timestamptz not null,
  last_received_at timestamptz not null,
  merged_into_packet_id uuid references public.whatsapp_commercial_packets(id) on delete restrict,
  split_from_packet_id uuid references public.whatsapp_commercial_packets(id) on delete restrict,
  version bigint not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (merged_into_packet_id is null or merged_into_packet_id <> id),
  check (split_from_packet_id is null or split_from_packet_id <> id)
);

create table public.whatsapp_commercial_evidence (
  id uuid primary key default gen_random_uuid(),
  packet_id uuid not null references public.whatsapp_commercial_packets(id) on delete restrict,
  potential_order_id uuid not null references public.whatsapp_potential_orders(id) on delete restrict,
  source_message_id uuid not null unique references public.whatsapp_inbound_messages(id) on delete restrict,
  provider_message_id text not null unique,
  sender_key text not null,
  provider_sent_at timestamptz not null,
  deterministic_sequence bigint not null,
  evidence_kind text not null check(evidence_kind in ('TEXT','IMAGE','DOCUMENT','VIDEO','AUDIO','OTHER')),
  original_body text not null,
  original_payload jsonb not null,
  correction_of_source_message_id uuid references public.whatsapp_inbound_messages(id) on delete restrict,
  media_count integer not null default 0 check(media_count >= 0),
  processing_state text not null default 'PENDING' check(processing_state in ('PENDING','PROCESSING','SUCCEEDED','UNSUPPORTED','CORRUPT','UNREADABLE','TIMED_OUT','FAILED')),
  processing_detail jsonb not null default '{}'::jsonb,
  captured_at timestamptz not null default now(),
  processed_at timestamptz,
  unique(packet_id,deterministic_sequence)
);

create table public.whatsapp_packet_audit_log (
  id bigint generated always as identity primary key,
  packet_id uuid not null references public.whatsapp_commercial_packets(id) on delete restrict,
  action text not null,
  actor_id uuid references public.users(id) on delete restrict,
  evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.whatsapp_media_processing_events (
  id bigint generated always as identity primary key,
  evidence_id uuid not null references public.whatsapp_commercial_evidence(id) on delete restrict,
  attempt_key text not null,
  state text not null check(state in ('SUCCEEDED','UNSUPPORTED','CORRUPT','UNREADABLE','TIMED_OUT','FAILED')),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(evidence_id,attempt_key)
);

create table public.whatsapp_packet_routing_events (
  id bigint generated always as identity primary key,
  source_packet_id uuid not null references public.whatsapp_commercial_packets(id) on delete restrict,
  target_packet_id uuid not null references public.whatsapp_commercial_packets(id) on delete restrict,
  evidence_ids uuid[] not null check(cardinality(evidence_ids)>0),
  action text not null check(action in ('SPLIT','MERGE')),
  reason text not null check(length(btrim(reason))>=8),
  actor_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  check(source_packet_id<>target_packet_id)
);

create index whatsapp_commercial_packets_queue_idx on public.whatsapp_commercial_packets(status,processing_state,last_received_at);
create index whatsapp_commercial_packets_sender_idx on public.whatsapp_commercial_packets(sender_key,conversation_key,last_received_at desc);
create index whatsapp_commercial_evidence_order_idx on public.whatsapp_commercial_evidence(packet_id,provider_sent_at,provider_message_id);

alter table public.whatsapp_commercial_packets enable row level security;
alter table public.whatsapp_commercial_evidence enable row level security;
alter table public.whatsapp_packet_audit_log enable row level security;
alter table public.whatsapp_media_processing_events enable row level security;
alter table public.whatsapp_packet_routing_events enable row level security;
revoke all on public.whatsapp_commercial_packets,public.whatsapp_commercial_evidence,public.whatsapp_packet_audit_log,public.whatsapp_media_processing_events,public.whatsapp_packet_routing_events from public,anon,authenticated;
grant select on public.whatsapp_commercial_packets,public.whatsapp_commercial_evidence,public.whatsapp_packet_audit_log,public.whatsapp_media_processing_events,public.whatsapp_packet_routing_events to authenticated;
create policy wa4_packets_read on public.whatsapp_commercial_packets for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));
create policy wa4_evidence_read on public.whatsapp_commercial_evidence for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));
create policy wa4_audit_read on public.whatsapp_packet_audit_log for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));
create policy wa4_media_events_read on public.whatsapp_media_processing_events for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));
create policy wa4_routing_events_read on public.whatsapp_packet_routing_events for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));

create trigger wa4_evidence_immutable before update or delete on public.whatsapp_commercial_evidence for each row execute function public.wa1_audit_immutable();
create trigger wa4_audit_immutable before update or delete on public.whatsapp_packet_audit_log for each row execute function public.wa1_audit_immutable();
create trigger wa4_media_events_immutable before update or delete on public.whatsapp_media_processing_events for each row execute function public.wa1_audit_immutable();
create trigger wa4_routing_events_immutable before update or delete on public.whatsapp_packet_routing_events for each row execute function public.wa1_audit_immutable();

create function public.capture_whatsapp_commercial_fragment(
  p_source_message_id uuid,
  p_packet_id uuid default null,
  p_conversation_key text default null,
  p_correction_of_source_message_id uuid default null,
  p_media_count integer default 0,
  p_interpretation_failed boolean default false,
  p_evidence jsonb default '{}'::jsonb
) returns public.whatsapp_commercial_evidence
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_message public.whatsapp_inbound_messages%rowtype; v_po public.whatsapp_potential_orders%rowtype; v_packet public.whatsapp_commercial_packets%rowtype; v_existing public.whatsapp_commercial_evidence%rowtype; v_result public.whatsapp_commercial_evidence%rowtype; v_sender text; v_conversation text; v_sequence bigint; v_kind text; v_failure text;
begin
 if auth.uid() is not null then raise exception 'WA4_TRUSTED_INGRESS_REQUIRED' using errcode='P0001'; end if;
 select * into v_message from public.whatsapp_inbound_messages where id=p_source_message_id;
 if not found then raise exception 'WA4_SOURCE_MESSAGE_NOT_FOUND'; end if;
 if nullif(btrim(v_message.provider_message_id),'') is null then raise exception 'WA4_PROVIDER_ID_REQUIRED'; end if;
 select * into v_existing from public.whatsapp_commercial_evidence where provider_message_id=v_message.provider_message_id;
 if found then return v_existing; end if;
 v_sender:=lower(regexp_replace(v_message.sender_phone,'\D','','g'));
 v_conversation:=coalesce(nullif(btrim(p_conversation_key),''),v_message.provider_message_id);
 if p_packet_id is not null then
   select * into v_packet from public.whatsapp_commercial_packets where id=p_packet_id for update;
   if not found then raise exception 'WA4_PACKET_NOT_FOUND'; end if;
   if v_packet.status in ('MERGED','SPLIT','CLOSED') then raise exception 'WA4_PACKET_NOT_OPEN'; end if;
   if v_packet.sender_key<>v_sender or v_packet.conversation_key<>v_conversation then raise exception 'WA4_PACKET_BOUNDARY_MISMATCH'; end if;
   select * into v_po from public.whatsapp_potential_orders where id=v_packet.potential_order_id for update;
   if v_po.disposition<>'ACTIVE_PENDING' then raise exception 'WA4_POTENTIAL_ORDER_TERMINAL'; end if;
 else
   if nullif(btrim(p_conversation_key),'') is not null then
     select p.* into v_packet from public.whatsapp_commercial_evidence e
       join public.whatsapp_commercial_packets p on p.id=e.packet_id
      where e.provider_message_id=v_conversation and e.sender_key=v_sender
        and p.status in ('OPEN','AWAITING_MEDIA','FAILED_MEDIA') for update of p;
     if found then v_conversation:=v_packet.conversation_key; end if;
   end if;
   if not found and nullif(btrim(p_conversation_key),'') is not null then
     select * into v_packet from public.whatsapp_commercial_packets
      where sender_key=v_sender and conversation_key=v_conversation and status in ('OPEN','AWAITING_MEDIA','FAILED_MEDIA')
      order by created_at,id limit 1 for update;
   end if;
   if found then
     select * into v_po from public.whatsapp_potential_orders where id=v_packet.potential_order_id for update;
     if v_po.disposition<>'ACTIVE_PENDING' then raise exception 'WA4_POTENTIAL_ORDER_TERMINAL'; end if;
   end if;
   if not found then
   -- A missing packet is intentionally isolated. Time proximity alone is not a
   -- commercial correlation key and must never combine two customer orders.
   insert into public.whatsapp_potential_orders(source_message_id,provider_message_id,sender_key,source_fingerprint,source_evidence,state,queue,next_action,first_received_at,last_evidence_at)
   values(v_message.id,v_message.provider_message_id,v_sender,
     encode(extensions.digest('wa4|'||v_sender||'|'||v_message.provider_message_id,'sha256'),'hex'),
     jsonb_build_array(jsonb_build_object('message_id',v_message.id,'provider_message_id',v_message.provider_message_id,'body',v_message.message_body,'type',v_message.message_type,'raw_payload',v_message.raw_payload,'captured_at',now()),coalesce(p_evidence,'{}')||jsonb_build_object('wa4_packetized',true)),
     case when p_interpretation_failed then 'FAILED_INTERPRETATION' else 'UNASSIGNED' end,
     case when p_interpretation_failed then 'WA_FAILED_INTERPRETATION' else 'WA_COMMERCIAL_UNASSIGNED' end,
     case when p_interpretation_failed then 'HUMAN_INTERPRETATION' else 'ASSIGN_OWNER' end,v_message.received_at,v_message.received_at)
   returning * into v_po;
   insert into public.whatsapp_potential_order_audit_log(potential_order_id,action,to_state,evidence)
   values(v_po.id,'WA4_PACKET_CAPTURED',v_po.state,coalesce(p_evidence,'{}'));
   insert into public.whatsapp_commercial_packets(potential_order_id,sender_key,conversation_key,status,processing_state,first_received_at,last_received_at)
   values(v_po.id,v_sender,v_conversation,case when p_media_count>0 then 'AWAITING_MEDIA' else 'OPEN' end,case when p_media_count>0 then 'PENDING' else 'READY' end,v_message.received_at,v_message.received_at)
   returning * into v_packet;
   insert into public.whatsapp_packet_audit_log(packet_id,action,evidence) values(v_packet.id,'PACKET_CREATED',jsonb_build_object('source_message_id',v_message.id));
   end if;
 end if;
 if p_correction_of_source_message_id is not null and not exists(select 1 from public.whatsapp_commercial_evidence where packet_id=v_packet.id and source_message_id=p_correction_of_source_message_id) then raise exception 'WA4_CORRECTION_SOURCE_NOT_IN_PACKET'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_packet.id::text,0));
 select coalesce(max(deterministic_sequence),0)+1 into v_sequence from public.whatsapp_commercial_evidence where packet_id=v_packet.id;
 v_kind:=case lower(coalesce(v_message.message_type,'text')) when 'text' then 'TEXT' when 'image' then 'IMAGE' when 'document' then 'DOCUMENT' when 'video' then 'VIDEO' when 'audio' then 'AUDIO' else 'OTHER' end;
 v_failure:=case when p_interpretation_failed then case when p_media_count>0 then 'UNREADABLE' else 'FAILED' end else case when p_media_count>0 then 'PENDING' else 'SUCCEEDED' end end;
 insert into public.whatsapp_commercial_evidence(packet_id,potential_order_id,source_message_id,provider_message_id,sender_key,provider_sent_at,deterministic_sequence,evidence_kind,original_body,original_payload,correction_of_source_message_id,media_count,processing_state,processing_detail)
 values(v_packet.id,v_po.id,v_message.id,v_message.provider_message_id,v_sender,v_message.received_at,v_sequence,v_kind,v_message.message_body,coalesce(v_message.raw_payload,'{}'),p_correction_of_source_message_id,greatest(coalesce(p_media_count,0),0),v_failure,coalesce(p_evidence,'{}')) returning * into v_result;
 perform set_config('app.wa1_governed_mutation','on',true);
 update public.whatsapp_potential_orders set source_evidence=source_evidence||jsonb_build_array(jsonb_build_object('wa4_evidence_id',v_result.id,'packet_id',v_packet.id,'message_id',v_message.id,'provider_message_id',v_message.provider_message_id,'sequence',v_sequence,'kind',v_kind,'correction_of',p_correction_of_source_message_id,'captured_at',v_result.captured_at)),last_evidence_at=greatest(last_evidence_at,v_message.received_at),updated_at=now(),state=case when p_interpretation_failed then 'FAILED_INTERPRETATION' else state end,queue=case when p_interpretation_failed then 'WA_FAILED_INTERPRETATION' else queue end,next_action=case when p_interpretation_failed then 'HUMAN_INTERPRETATION' else next_action end where id=v_po.id;
 perform set_config('app.wa1_governed_mutation','off',true);
 update public.whatsapp_commercial_packets set last_received_at=greatest(last_received_at,v_message.received_at),version=version+1,status=case when p_media_count>0 then 'AWAITING_MEDIA' else status end,processing_state=case when p_interpretation_failed then 'HUMAN_REVIEW' when p_media_count>0 then 'PENDING' else processing_state end,updated_at=now() where id=v_packet.id;
 insert into public.whatsapp_packet_audit_log(packet_id,action,evidence) values(v_packet.id,case when p_correction_of_source_message_id is null then 'FRAGMENT_CAPTURED' else 'CORRECTION_CAPTURED' end,jsonb_build_object('evidence_id',v_result.id,'source_message_id',v_message.id,'sequence',v_sequence));
 return v_result;
exception when unique_violation then
 select * into v_result from public.whatsapp_commercial_evidence where provider_message_id=v_message.provider_message_id;
 if found then return v_result; end if;
 raise;
when others then perform set_config('app.wa1_governed_mutation','off',true); raise;
end $$;

create function public.route_whatsapp_packet_evidence(p_source_packet_id uuid,p_target_packet_id uuid,p_evidence_ids uuid[],p_action text,p_reason text) returns bigint
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_source public.whatsapp_commercial_packets%rowtype; v_target public.whatsapp_commercial_packets%rowtype; v_id bigint;
begin
 if auth.uid() is null or not public.has_whatsapp_permission('wa.intake.triage') then raise exception 'WA4_TRIAGE_REQUIRED' using errcode='P0001'; end if;
 if p_action not in ('SPLIT','MERGE') then raise exception 'WA4_INVALID_ROUTE_ACTION'; end if;
 if nullif(btrim(p_reason),'') is null or length(btrim(p_reason))<8 then raise exception 'WA4_ROUTE_REASON_REQUIRED'; end if;
 select * into v_source from public.whatsapp_commercial_packets where id=p_source_packet_id for update;
 select * into v_target from public.whatsapp_commercial_packets where id=p_target_packet_id for update;
 if v_source.id is null or v_target.id is null then raise exception 'WA4_PACKET_NOT_FOUND'; end if;
 if v_source.sender_key<>v_target.sender_key then raise exception 'WA4_PACKET_BOUNDARY_MISMATCH'; end if;
 if exists(select 1 from unnest(p_evidence_ids) x(id) where not exists(select 1 from public.whatsapp_commercial_evidence e where e.id=x.id and e.packet_id=p_source_packet_id)) then raise exception 'WA4_EVIDENCE_NOT_IN_SOURCE_PACKET'; end if;
 insert into public.whatsapp_packet_routing_events(source_packet_id,target_packet_id,evidence_ids,action,reason,actor_id)
 values(p_source_packet_id,p_target_packet_id,p_evidence_ids,p_action,btrim(p_reason),auth.uid()) returning id into v_id;
 insert into public.whatsapp_packet_audit_log(packet_id,action,actor_id,evidence) values(p_source_packet_id,'EVIDENCE_'||p_action,auth.uid(),jsonb_build_object('routing_event_id',v_id,'target_packet_id',p_target_packet_id,'evidence_ids',p_evidence_ids,'reason',btrim(p_reason)));
 return v_id;
end $$;

create function public.complete_whatsapp_media_processing(p_provider_message_id text,p_state text,p_attempt_key text,p_detail jsonb default '{}') returns public.whatsapp_commercial_evidence
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.whatsapp_commercial_evidence%rowtype; v_packet_state text;
begin
 if auth.uid() is not null then raise exception 'WA4_TRUSTED_PROCESSOR_REQUIRED' using errcode='P0001'; end if;
 if p_state not in ('SUCCEEDED','UNSUPPORTED','CORRUPT','UNREADABLE','TIMED_OUT','FAILED') then raise exception 'WA4_INVALID_MEDIA_STATE'; end if;
 select * into v_row from public.whatsapp_commercial_evidence where provider_message_id=p_provider_message_id for update;
 if not found then raise exception 'WA4_EVIDENCE_NOT_FOUND'; end if;
 if nullif(btrim(p_attempt_key),'') is null then raise exception 'WA4_ATTEMPT_KEY_REQUIRED'; end if;
 insert into public.whatsapp_media_processing_events(evidence_id,attempt_key,state,detail)
 values(v_row.id,btrim(p_attempt_key),p_state,coalesce(p_detail,'{}')) on conflict(evidence_id,attempt_key) do nothing;
 v_packet_state:=case when p_state='SUCCEEDED' then 'READY' else 'HUMAN_REVIEW' end;
 update public.whatsapp_commercial_packets set status=case when p_state='SUCCEEDED' then 'OPEN' else 'FAILED_MEDIA' end,processing_state=v_packet_state,updated_at=now(),version=version+1 where id=v_row.packet_id;
 insert into public.whatsapp_packet_audit_log(packet_id,action,evidence) values(v_row.packet_id,'MEDIA_PROCESSING_'||p_state,jsonb_build_object('evidence_id',v_row.id,'detail',coalesce(p_detail,'{}')));
 if p_state<>'SUCCEEDED' then
   perform set_config('app.wa1_governed_mutation','on',true);
   update public.whatsapp_potential_orders set state='FAILED_INTERPRETATION',queue='WA_FAILED_INTERPRETATION',next_action='REVIEW_MEDIA_EVIDENCE',updated_at=now() where id=v_row.potential_order_id and disposition='ACTIVE_PENDING';
   perform set_config('app.wa1_governed_mutation','off',true);
 end if;
 return v_row;
exception when others then
 perform set_config('app.wa1_governed_mutation','off',true); raise;
end $$;

revoke all on function public.capture_whatsapp_commercial_fragment(uuid,uuid,text,uuid,integer,boolean,jsonb),public.complete_whatsapp_media_processing(text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.capture_whatsapp_commercial_fragment(uuid,uuid,text,uuid,integer,boolean,jsonb),public.complete_whatsapp_media_processing(text,text,text,jsonb) to service_role;
revoke all on function public.route_whatsapp_packet_evidence(uuid,uuid,uuid[],text,text) from public,anon;
grant execute on function public.route_whatsapp_packet_evidence(uuid,uuid,uuid[],text,text) to authenticated,service_role;

comment on table public.whatsapp_commercial_evidence is 'WA-4 immutable provider-message evidence. Ordering is provider time, provider id and an advisory-lock sequence; processing outcomes append audit without replacing source.';
comment on function public.capture_whatsapp_commercial_fragment(uuid,uuid,text,uuid,integer,boolean,jsonb) is 'Trusted WA-4 ingress. Default isolation prevents cross-order stitching; continuation requires an explicit same-sender/conversation packet.';
