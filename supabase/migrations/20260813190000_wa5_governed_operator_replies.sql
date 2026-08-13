-- WA-5: Core-authoritative, recipient-bound, retry-safe operator replies.
-- Additive/roll-forward migration. No source evidence or prior outbound history is removed.

insert into public.access_permissions(permission_key,description,risk_level,is_active,requires_step_up)
values('wa.reply.send','Send governed WhatsApp operator replies','sensitive',true,false)
on conflict(permission_key) do update set description=excluded.description,risk_level=excluded.risk_level,is_active=true;

insert into public.role_permission_grants(role_key,permission_key,effect)
values('super_admin','wa.reply.send','allow'),('admin','wa.reply.send','allow'),('support_executive','wa.reply.send','allow')
on conflict(role_key,permission_key) do update set effect=excluded.effect;

create table public.whatsapp_operator_reply_outbox (
 id uuid primary key default gen_random_uuid(),
 packet_id uuid not null references public.whatsapp_message_packets(id) on delete restrict,
 contact_id uuid not null references public.whatsapp_contacts(id) on delete restrict,
 potential_order_id uuid references public.whatsapp_potential_orders(id) on delete restrict,
 clarification_task_id uuid references public.whatsapp_order_clarification_tasks(id) on delete restrict,
 recipient_phone_e164 text not null check(recipient_phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
 message_body text not null check(length(btrim(message_body)) between 1 and 4000),
 message_type text not null default 'TEXT' check(message_type in('TEXT','TEMPLATE','MEDIA')),
 template_name text,
 template_language text,
 media_reference text,
 disclosure_scope text[] not null default '{}',
 idempotency_key text not null,
 status text not null default 'QUEUED' check(status in('QUEUED','SENDING','ACCEPTANCE_UNKNOWN','ACCEPTED','DELIVERED','READ','FAILED_RETRYABLE','FAILED_FINAL','CANCELLED')),
 provider text,
 provider_message_id text,
 attempt_count integer not null default 0 check(attempt_count>=0),
 next_attempt_at timestamptz not null default now(),
 lease_token uuid,
 lease_expires_at timestamptz,
 last_error_code text,
 last_error_detail text,
 created_by uuid not null references public.users(id) on delete restrict,
 created_at timestamptz not null default now(),
 accepted_at timestamptz,
 delivered_at timestamptz,
 read_at timestamptz,
 updated_at timestamptz not null default now(),
 unique(packet_id,idempotency_key),
 check((message_type='TEMPLATE')=(template_name is not null and template_language is not null)),
 check((message_type='MEDIA')=(media_reference is not null)),
 check(provider_message_id is null or status in('ACCEPTED','DELIVERED','READ'))
);
create unique index whatsapp_operator_reply_provider_unique on public.whatsapp_operator_reply_outbox(provider,provider_message_id) where provider_message_id is not null;
create index whatsapp_operator_reply_claim_idx on public.whatsapp_operator_reply_outbox(status,next_attempt_at,created_at);

create table public.whatsapp_operator_reply_events (
 id bigint generated always as identity primary key,
 reply_id uuid not null references public.whatsapp_operator_reply_outbox(id) on delete restrict,
 event_type text not null,
 actor_id uuid references public.users(id) on delete restrict,
 evidence jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
alter table public.whatsapp_operator_reply_outbox enable row level security;
alter table public.whatsapp_operator_reply_events enable row level security;
revoke all on public.whatsapp_operator_reply_outbox,public.whatsapp_operator_reply_events from public,anon,authenticated;
grant select on public.whatsapp_operator_reply_outbox,public.whatsapp_operator_reply_events to authenticated;
create policy wa5_reply_read on public.whatsapp_operator_reply_outbox for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));
create policy wa5_reply_events_read on public.whatsapp_operator_reply_events for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));
create trigger wa5_reply_events_immutable before update or delete on public.whatsapp_operator_reply_events for each row execute function public.wa1_audit_immutable();

create or replace function public.has_whatsapp_permission(p_permission_key text) returns boolean
language sql stable security definer set search_path=public,auth,pg_temp as $$
 select auth.uid() is not null
   and exists(select 1 from public.users u where u.id=auth.uid() and coalesce(u.is_active,true) and u.deleted_at is null)
   and p_permission_key=any(array['wa.intake.read','wa.intake.triage','wa.intake.assign','wa.intake.close','wa.draft.manage','wa.draft.promote','wa.reply.send'])
   and public.has_app_permission(auth.uid(),p_permission_key,null,null)
$$;
create or replace function public.get_my_whatsapp_permissions() returns text[]
language sql stable security definer set search_path=public,auth,pg_temp as $$
 select coalesce(array_agg(p order by p),'{}'::text[]) from unnest(array[
  'wa.intake.read','wa.intake.triage','wa.intake.assign','wa.intake.close','wa.draft.manage','wa.draft.promote','wa.reply.send'
 ]) p where public.has_whatsapp_permission(p)
$$;

create function public.enqueue_whatsapp_operator_reply(p_packet_id uuid,p_contact_id uuid,p_recipient_phone text,p_message_body text,p_idempotency_key text,p_potential_order_id uuid default null,p_clarification_task_id uuid default null,p_message_type text default 'TEXT',p_template_name text default null,p_template_language text default null,p_media_reference text default null,p_disclosure_scope text[] default '{}') returns public.whatsapp_operator_reply_outbox
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_contact public.whatsapp_contacts%rowtype; v_packet public.whatsapp_message_packets%rowtype; v_phone text; v_result public.whatsapp_operator_reply_outbox%rowtype;
begin
 if auth.uid() is null or not public.has_whatsapp_permission('wa.reply.send') then raise exception 'WA5_REPLY_SEND_REQUIRED' using errcode='P0001'; end if;
 select * into v_packet from public.whatsapp_message_packets where id=p_packet_id;
 select * into v_contact from public.whatsapp_contacts where id=p_contact_id;
 if v_packet.id is null or v_contact.id is null or v_packet.contact_id<>v_contact.id then raise exception 'WA5_PACKET_CONTACT_MISMATCH'; end if;
 v_phone:='+'||regexp_replace(v_contact.phone_number,'\D','','g');
 if v_phone<>('+'||regexp_replace(p_recipient_phone,'\D','','g')) then raise exception 'WA5_RECIPIENT_MISMATCH'; end if;
 if p_potential_order_id is not null and not exists(select 1 from public.whatsapp_potential_orders po where po.id=p_potential_order_id and po.sender_key=regexp_replace(v_phone,'\D','','g')) then raise exception 'WA5_POTENTIAL_ORDER_BOUNDARY_MISMATCH'; end if;
 if p_clarification_task_id is not null and not exists(select 1 from public.whatsapp_order_clarification_tasks t where t.id=p_clarification_task_id and t.potential_order_id=p_potential_order_id and t.status='OPEN') then raise exception 'WA5_CLARIFICATION_BOUNDARY_MISMATCH'; end if;
 insert into public.whatsapp_operator_reply_outbox(packet_id,contact_id,potential_order_id,clarification_task_id,recipient_phone_e164,message_body,message_type,template_name,template_language,media_reference,disclosure_scope,idempotency_key,created_by)
 values(p_packet_id,p_contact_id,p_potential_order_id,p_clarification_task_id,v_phone,btrim(p_message_body),upper(p_message_type),nullif(btrim(p_template_name),''),nullif(btrim(p_template_language),''),nullif(btrim(p_media_reference),''),coalesce(p_disclosure_scope,'{}'),btrim(p_idempotency_key),auth.uid())
 on conflict(packet_id,idempotency_key) do update set idempotency_key=excluded.idempotency_key returning * into v_result;
 insert into public.whatsapp_operator_reply_events(reply_id,event_type,actor_id,evidence) values(v_result.id,'ENQUEUED_OR_REPLAYED',auth.uid(),jsonb_build_object('permission','wa.reply.send','recipient',v_phone,'clarification_task_id',p_clarification_task_id));
 return v_result;
end $$;

create function public.claim_whatsapp_operator_reply(p_worker_id text,p_reply_id uuid default null,p_lease_seconds integer default 60) returns public.whatsapp_operator_reply_outbox
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_result public.whatsapp_operator_reply_outbox%rowtype;
begin
 if auth.uid() is not null then raise exception 'WA5_SERVICE_ROLE_REQUIRED'; end if;
 select * into v_result from public.whatsapp_operator_reply_outbox where status in('QUEUED','FAILED_RETRYABLE') and next_attempt_at<=now() and (p_reply_id is null or id=p_reply_id) order by created_at for update skip locked limit 1;
 if not found then return null; end if;
 update public.whatsapp_operator_reply_outbox set status='SENDING',attempt_count=attempt_count+1,lease_token=gen_random_uuid(),lease_expires_at=now()+make_interval(secs=>greatest(15,least(p_lease_seconds,300))),updated_at=now() where id=v_result.id returning * into v_result;
 insert into public.whatsapp_operator_reply_events(reply_id,event_type,evidence) values(v_result.id,'CLAIMED',jsonb_build_object('worker_id',p_worker_id,'attempt',v_result.attempt_count,'lease_token',v_result.lease_token));
 return v_result;
end $$;

create function public.complete_whatsapp_operator_reply(p_reply_id uuid,p_lease_token uuid,p_provider text,p_provider_message_id text) returns public.whatsapp_operator_reply_outbox
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_result public.whatsapp_operator_reply_outbox%rowtype;
begin
 if auth.uid() is not null then raise exception 'WA5_SERVICE_ROLE_REQUIRED'; end if;
 update public.whatsapp_operator_reply_outbox set status='ACCEPTED',provider=btrim(p_provider),provider_message_id=btrim(p_provider_message_id),accepted_at=now(),lease_token=null,lease_expires_at=null,last_error_code=null,last_error_detail=null,updated_at=now() where id=p_reply_id and status='SENDING' and lease_token=p_lease_token returning * into v_result;
 if not found then raise exception 'WA5_STALE_OR_INVALID_LEASE'; end if;
 insert into public.whatsapp_operator_reply_events(reply_id,event_type,evidence) values(v_result.id,'PROVIDER_ACCEPTED',jsonb_build_object('provider',p_provider,'provider_message_id',p_provider_message_id)); return v_result;
end $$;

create function public.fail_whatsapp_operator_reply(p_reply_id uuid,p_lease_token uuid,p_error_code text,p_error_detail text,p_acceptance_unknown boolean default false) returns public.whatsapp_operator_reply_outbox
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_result public.whatsapp_operator_reply_outbox%rowtype;
begin
 if auth.uid() is not null then raise exception 'WA5_SERVICE_ROLE_REQUIRED'; end if;
 update public.whatsapp_operator_reply_outbox set status=case when p_acceptance_unknown then 'ACCEPTANCE_UNKNOWN' when attempt_count<5 then 'FAILED_RETRYABLE' else 'FAILED_FINAL' end,next_attempt_at=case when p_acceptance_unknown then 'infinity'::timestamptz else now()+make_interval(secs=>least(3600,30*(2^greatest(attempt_count-1,0))::integer)) end,lease_token=null,lease_expires_at=null,last_error_code=btrim(p_error_code),last_error_detail=left(p_error_detail,1000),updated_at=now() where id=p_reply_id and status='SENDING' and lease_token=p_lease_token returning * into v_result;
 if not found then raise exception 'WA5_STALE_OR_INVALID_LEASE'; end if;
 insert into public.whatsapp_operator_reply_events(reply_id,event_type,evidence) values(v_result.id,case when p_acceptance_unknown then 'PROVIDER_ACCEPTANCE_UNKNOWN' else 'SEND_FAILED' end,jsonb_build_object('error_code',p_error_code,'retryable',v_result.status='FAILED_RETRYABLE')); return v_result;
end $$;

create function public.record_whatsapp_operator_reply_status(p_reply_id uuid,p_provider text,p_provider_message_id text,p_status text,p_evidence jsonb default '{}') returns public.whatsapp_operator_reply_outbox
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_result public.whatsapp_operator_reply_outbox%rowtype; v_status text:=upper(btrim(p_status));
begin
 if auth.uid() is not null then raise exception 'WA5_SERVICE_ROLE_REQUIRED'; end if;
 if v_status not in('ACCEPTED','DELIVERED','READ') then raise exception 'WA5_INVALID_PROVIDER_STATUS'; end if;
 update public.whatsapp_operator_reply_outbox
 set status=v_status,provider=btrim(p_provider),provider_message_id=btrim(p_provider_message_id),
     accepted_at=coalesce(accepted_at,now()),
     delivered_at=case when v_status in('DELIVERED','READ') then coalesce(delivered_at,now()) else delivered_at end,
     read_at=case when v_status='READ' then coalesce(read_at,now()) else read_at end,
     lease_token=null,lease_expires_at=null,last_error_code=null,last_error_detail=null,updated_at=now()
 where (id=p_reply_id or (p_reply_id is null and provider=btrim(p_provider) and provider_message_id=btrim(p_provider_message_id)))
   and status in('SENDING','ACCEPTANCE_UNKNOWN','ACCEPTED','DELIVERED','READ')
   and case status when 'SENDING' then 0 when 'ACCEPTANCE_UNKNOWN' then 0 when 'ACCEPTED' then 1 when 'DELIVERED' then 2 when 'READ' then 3 end
       <= case v_status when 'ACCEPTED' then 1 when 'DELIVERED' then 2 when 'READ' then 3 end
   and (provider_message_id is null or (provider=btrim(p_provider) and provider_message_id=btrim(p_provider_message_id)))
 returning * into v_result;
 if not found then raise exception 'WA5_STATUS_BOUNDARY_OR_REGRESSION'; end if;
 insert into public.whatsapp_operator_reply_events(reply_id,event_type,evidence)
 values(v_result.id,'PROVIDER_'||v_status,coalesce(p_evidence,'{}')||jsonb_build_object('provider',p_provider,'provider_message_id',p_provider_message_id));
 return v_result;
end $$;

revoke all on function public.enqueue_whatsapp_operator_reply(uuid,uuid,text,text,text,uuid,uuid,text,text,text,text,text[]),public.claim_whatsapp_operator_reply(text,uuid,integer),public.complete_whatsapp_operator_reply(uuid,uuid,text,text),public.fail_whatsapp_operator_reply(uuid,uuid,text,text,boolean),public.record_whatsapp_operator_reply_status(uuid,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.enqueue_whatsapp_operator_reply(uuid,uuid,text,text,text,uuid,uuid,text,text,text,text,text[]) to authenticated,service_role;
grant execute on function public.claim_whatsapp_operator_reply(text,uuid,integer),public.complete_whatsapp_operator_reply(uuid,uuid,text,text),public.fail_whatsapp_operator_reply(uuid,uuid,text,text,boolean),public.record_whatsapp_operator_reply_status(uuid,text,text,text,jsonb) to service_role;
