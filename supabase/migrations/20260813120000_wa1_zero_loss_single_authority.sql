-- WA-1: one durable, reconcilable WhatsApp commercial-order authority.
create table public.whatsapp_potential_orders (
  id uuid primary key default gen_random_uuid(),
  source_message_id uuid not null references public.whatsapp_inbound_messages(id) on delete restrict,
  provider_message_id text,
  sender_key text not null,
  source_fingerprint text not null,
  source_evidence jsonb not null default '[]'::jsonb,
  domain text not null default 'B2B' check (domain = 'B2B'),
  state text not null default 'NEW' check (state in ('NEW','UNASSIGNED','FAILED_INTERPRETATION','AWAITING_CLARIFICATION','AGEING','AT_RISK','ESCALATED','CONVERTED','EXPLICITLY_CLOSED')),
  disposition text not null default 'ACTIVE_PENDING' check (disposition in ('ACTIVE_PENDING','CONVERTED','EXPLICITLY_CLOSED')),
  owner_id uuid references public.users(id) on delete restrict,
  queue text not null default 'WA_COMMERCIAL_UNASSIGNED',
  next_action text not null default 'TRIAGE_INTAKE',
  next_action_due_at timestamptz not null default (now() + interval '30 minutes'),
  sla_state text not null default 'ON_TIME' check (sla_state in ('ON_TIME','AGEING','AT_RISK','BREACHED')),
  sales_order_draft_id uuid references public.sales_order_drafts(id) on delete restrict,
  sales_order_id uuid references public.orders(id) on delete restrict,
  closed_reason text,
  closed_by uuid references public.users(id) on delete restrict,
  closed_at timestamptz,
  first_received_at timestamptz not null,
  last_evidence_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_potential_orders_source_unique unique(source_message_id),
  constraint whatsapp_potential_orders_outcome_link check (
    (disposition='CONVERTED' and state='CONVERTED' and sales_order_draft_id is not null and sales_order_id is not null and closed_at is null)
    or (disposition='EXPLICITLY_CLOSED' and state='EXPLICITLY_CLOSED' and closed_reason is not null and closed_by is not null and closed_at is not null and sales_order_id is null)
    or (disposition='ACTIVE_PENDING' and state not in ('CONVERTED','EXPLICITLY_CLOSED') and sales_order_id is null and closed_at is null)
  )
);

create table public.whatsapp_potential_order_audit_log (
  id bigint generated always as identity primary key,
  potential_order_id uuid not null references public.whatsapp_potential_orders(id) on delete restrict,
  action text not null,
  from_state text,
  to_state text not null,
  actor_id uuid references public.users(id) on delete restrict,
  evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index whatsapp_potential_orders_queue_idx on public.whatsapp_potential_orders(queue,state,next_action_due_at);
create index whatsapp_potential_orders_owner_idx on public.whatsapp_potential_orders(owner_id,state);
create index whatsapp_potential_orders_evidence_gin_idx on public.whatsapp_potential_orders using gin(source_evidence jsonb_path_ops);
create index whatsapp_potential_orders_sender_open_idx on public.whatsapp_potential_orders(sender_key,last_evidence_at desc)
where disposition='ACTIVE_PENDING';
create unique index whatsapp_potential_orders_open_fingerprint_unique on public.whatsapp_potential_orders(source_fingerprint)
where disposition='ACTIVE_PENDING';

alter table public.whatsapp_potential_orders enable row level security;
alter table public.whatsapp_potential_order_audit_log enable row level security;
revoke all on public.whatsapp_potential_orders, public.whatsapp_potential_order_audit_log from public, anon, authenticated;
grant select on public.whatsapp_potential_orders, public.whatsapp_potential_order_audit_log to authenticated;

create policy whatsapp_potential_orders_reader on public.whatsapp_potential_orders for select to authenticated
using (public.is_whatsapp_inbox_reader((select auth.uid())));
create policy whatsapp_potential_order_audit_reader on public.whatsapp_potential_order_audit_log for select to authenticated
using (public.is_whatsapp_inbox_reader((select auth.uid())));

create function public.wa1_audit_immutable() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin raise exception 'WA1_AUDIT_IMMUTABLE' using errcode='P0001'; end $$;
create trigger whatsapp_potential_order_audit_immutable before update or delete on public.whatsapp_potential_order_audit_log
for each row execute function public.wa1_audit_immutable();

create function public.wa1_direct_mutation_blocked() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if tg_op='DELETE' then raise exception 'WA1_DELETE_FORBIDDEN' using errcode='P0001'; end if;
  if current_setting('app.wa1_governed_mutation',true) is distinct from 'on' then
    raise exception 'WA1_GOVERNED_MUTATION_REQUIRED' using errcode='P0001';
  end if;
  return new;
end $$;
create trigger whatsapp_potential_order_governed_update before update or delete on public.whatsapp_potential_orders
for each row execute function public.wa1_direct_mutation_blocked();

create function public.capture_whatsapp_potential_order(
  p_source_message_id uuid,
  p_order_like boolean default true,
  p_interpretation_failed boolean default false,
  p_evidence jsonb default '{}'::jsonb
) returns public.whatsapp_potential_orders
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_message public.whatsapp_inbound_messages%rowtype; v_row public.whatsapp_potential_orders%rowtype; v_fingerprint text; v_sender_key text;
begin
  if auth.uid() is not null and not public.is_whatsapp_inbox_reader(auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='P0001'; end if;
  select * into v_message from public.whatsapp_inbound_messages where id=p_source_message_id;
  if not found then raise exception 'SOURCE_MESSAGE_NOT_FOUND'; end if;
  if not p_order_like and not p_interpretation_failed then raise exception 'COMMERCIAL_RISK_REQUIRED'; end if;
  v_sender_key:=lower(regexp_replace(v_message.sender_phone,'\D','','g'));
  v_fingerprint:=encode(extensions.digest(v_sender_key||'|'||lower(regexp_replace(btrim(v_message.message_body),'\s+',' ','g'))||'|'||coalesce(v_message.message_type,'text'),'sha256'),'hex');
  select * into v_row from public.whatsapp_potential_orders
   where source_message_id=p_source_message_id
      or source_evidence @> jsonb_build_array(jsonb_build_object('message_id',p_source_message_id))
   limit 1;
  if found then return v_row; end if;
  -- Fragments, corrections and forwards from the same sender join one open commercial packet.
  select * into v_row from public.whatsapp_potential_orders
   where sender_key=v_sender_key and disposition='ACTIVE_PENDING' and last_evidence_at >= v_message.received_at-interval '30 minutes'
   order by last_evidence_at desc limit 1 for update;
  if found then
    perform set_config('app.wa1_governed_mutation','on',true);
    update public.whatsapp_potential_orders set source_evidence=source_evidence||jsonb_build_array(jsonb_build_object('message_id',v_message.id,'provider_message_id',v_message.provider_message_id,'body',v_message.message_body,'type',v_message.message_type,'raw_payload',v_message.raw_payload,'captured_at',now()))||jsonb_build_array(coalesce(p_evidence,'{}'::jsonb)),
      last_evidence_at=greatest(last_evidence_at,v_message.received_at),updated_at=now(),state=case when p_interpretation_failed then 'FAILED_INTERPRETATION' else state end,
      queue=case when p_interpretation_failed then 'WA_FAILED_INTERPRETATION' else queue end,next_action=case when p_interpretation_failed then 'HUMAN_INTERPRETATION' else next_action end
    where id=v_row.id returning * into v_row;
    insert into public.whatsapp_potential_order_audit_log(potential_order_id,action,from_state,to_state,evidence) values(v_row.id,'SOURCE_EVIDENCE_ATTACHED',v_row.state,v_row.state,p_evidence);
    perform set_config('app.wa1_governed_mutation','off',true);
    return v_row;
  end if;
  perform set_config('app.wa1_governed_mutation','on',true);
  insert into public.whatsapp_potential_orders(source_message_id,provider_message_id,sender_key,source_fingerprint,source_evidence,state,queue,next_action,first_received_at,last_evidence_at)
  values(v_message.id,v_message.provider_message_id,v_sender_key,v_fingerprint,jsonb_build_array(jsonb_build_object('message_id',v_message.id,'provider_message_id',v_message.provider_message_id,'body',v_message.message_body,'type',v_message.message_type,'raw_payload',v_message.raw_payload,'captured_at',now()))||jsonb_build_array(coalesce(p_evidence,'{}'::jsonb)),
    case when p_interpretation_failed then 'FAILED_INTERPRETATION' else 'UNASSIGNED' end,
    case when p_interpretation_failed then 'WA_FAILED_INTERPRETATION' else 'WA_COMMERCIAL_UNASSIGNED' end,
    case when p_interpretation_failed then 'HUMAN_INTERPRETATION' else 'ASSIGN_OWNER' end,v_message.received_at,v_message.received_at)
  on conflict(source_fingerprint) where disposition='ACTIVE_PENDING' do update set
    source_evidence=public.whatsapp_potential_orders.source_evidence||excluded.source_evidence,
    last_evidence_at=greatest(public.whatsapp_potential_orders.last_evidence_at,excluded.last_evidence_at),updated_at=now()
  returning * into v_row;
  insert into public.whatsapp_potential_order_audit_log(potential_order_id,action,to_state,evidence)
  values(v_row.id,case when v_row.source_message_id=p_source_message_id then 'CAPTURED_OR_REPLAYED' else 'DUPLICATE_EVIDENCE_ATTACHED' end,v_row.state,p_evidence);
  perform set_config('app.wa1_governed_mutation','off',true);
  return v_row;
end $$;

create function public.transition_whatsapp_potential_order(
  p_potential_order_id uuid,p_to_state text,p_owner_id uuid,p_queue text,p_next_action text,p_due_at timestamptz,
  p_sales_order_draft_id uuid default null,p_sales_order_id uuid default null,p_close_reason text default null,p_expected_updated_at timestamptz default null,p_evidence jsonb default '{}'
) returns public.whatsapp_potential_orders
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_old public.whatsapp_potential_orders%rowtype; v_new public.whatsapp_potential_orders%rowtype; v_disp text; v_allowed boolean:=false;
begin
  if auth.uid() is null or not public.is_whatsapp_inbox_reader(auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='P0001'; end if;
  select * into v_old from public.whatsapp_potential_orders where id=p_potential_order_id for update;
  if not found then raise exception 'POTENTIAL_ORDER_NOT_FOUND'; end if;
  if p_expected_updated_at is not null and v_old.updated_at is distinct from p_expected_updated_at then raise exception 'STALE_TRANSITION'; end if;
  if v_old.disposition<>'ACTIVE_PENDING' then
    if v_old.state=p_to_state then return v_old; end if;
    raise exception 'TERMINAL_STATE_IMMUTABLE';
  end if;
  v_allowed := p_to_state in ('UNASSIGNED','FAILED_INTERPRETATION','AWAITING_CLARIFICATION','AGEING','AT_RISK','ESCALATED','EXPLICITLY_CLOSED')
    or (p_to_state='CONVERTED' and p_sales_order_draft_id is not null and p_sales_order_id is not null
      and exists(select 1 from public.sales_order_drafts d where d.id=p_sales_order_draft_id and d.promoted_order_id=p_sales_order_id and d.status='APPROVED_FOR_SO'));
  if not v_allowed then raise exception 'INVALID_WA1_TRANSITION'; end if;
  if p_to_state not in ('UNASSIGNED','FAILED_INTERPRETATION') and p_owner_id is null then raise exception 'OWNER_REQUIRED'; end if;
  if p_to_state='EXPLICITLY_CLOSED' and nullif(btrim(p_close_reason),'') is null then raise exception 'CLOSE_REASON_REQUIRED'; end if;
  v_disp:=case when p_to_state='CONVERTED' then 'CONVERTED' when p_to_state='EXPLICITLY_CLOSED' then 'EXPLICITLY_CLOSED' else 'ACTIVE_PENDING' end;
  perform set_config('app.wa1_governed_mutation','on',true);
  update public.whatsapp_potential_orders set state=p_to_state,disposition=v_disp,owner_id=p_owner_id,queue=coalesce(nullif(btrim(p_queue),''),queue),
    next_action=coalesce(nullif(btrim(p_next_action),''),next_action),next_action_due_at=coalesce(p_due_at,next_action_due_at),
    sla_state=case when p_to_state='AGEING' then 'AGEING' when p_to_state='AT_RISK' then 'AT_RISK' when p_to_state='ESCALATED' then 'BREACHED' else sla_state end,
    sales_order_draft_id=case when p_to_state='CONVERTED' then p_sales_order_draft_id else sales_order_draft_id end,
    sales_order_id=case when p_to_state='CONVERTED' then p_sales_order_id else null end,
    closed_reason=case when p_to_state='EXPLICITLY_CLOSED' then btrim(p_close_reason) else null end,
    closed_by=case when p_to_state='EXPLICITLY_CLOSED' then auth.uid() else null end,closed_at=case when p_to_state='EXPLICITLY_CLOSED' then now() else null end,updated_at=now()
  where id=p_potential_order_id returning * into v_new;
  insert into public.whatsapp_potential_order_audit_log(potential_order_id,action,from_state,to_state,actor_id,evidence)
  values(v_new.id,'STATE_TRANSITION',v_old.state,v_new.state,auth.uid(),coalesce(p_evidence,'{}'));
  perform set_config('app.wa1_governed_mutation','off',true);
  return v_new;
end $$;

create view public.whatsapp_potential_order_reconciliation with (security_invoker=true) as
with commercial_sources as (
 select m.id from public.whatsapp_inbound_messages m where coalesce((m.raw_payload->>'commercial_eligible')::boolean,false)
), accounted as (
 select s.id,p.disposition,p.state,p.owner_id from commercial_sources s left join lateral (
  select po.disposition,po.state,po.owner_id from public.whatsapp_potential_orders po
  where po.source_message_id=s.id or po.source_evidence @> jsonb_build_array(jsonb_build_object('message_id',s.id)) limit 1
 ) p on true
)
select count(*)::bigint potential_received,
 count(*) filter(where disposition='CONVERTED')::bigint converted,
 count(*) filter(where disposition='ACTIVE_PENDING')::bigint active_pending,
 count(*) filter(where disposition='EXPLICITLY_CLOSED')::bigint explicitly_closed,
 count(*) filter(where disposition is null)::bigint unaccounted_potential_orders,
 count(*) filter(where disposition='ACTIVE_PENDING' and (state='UNASSIGNED' or owner_id is null))::bigint unassigned,
 count(*) filter(where disposition='ACTIVE_PENDING' and state='FAILED_INTERPRETATION')::bigint failed_interpretation,
 count(*) filter(where disposition='ACTIVE_PENDING' and state in ('AT_RISK','ESCALATED'))::bigint at_risk_escalated
from accounted;
revoke all on public.whatsapp_potential_order_reconciliation from public,anon;
grant select on public.whatsapp_potential_order_reconciliation to authenticated;

revoke all on function public.capture_whatsapp_potential_order(uuid,boolean,boolean,jsonb) from public,anon,authenticated;
grant execute on function public.capture_whatsapp_potential_order(uuid,boolean,boolean,jsonb) to service_role;
revoke all on function public.transition_whatsapp_potential_order(uuid,text,uuid,text,text,timestamptz,uuid,uuid,text,timestamptz,jsonb) from public,anon;
grant execute on function public.transition_whatsapp_potential_order(uuid,text,uuid,text,text,timestamptz,uuid,uuid,text,timestamptz,jsonb) to authenticated,service_role;

comment on table public.whatsapp_potential_orders is 'WA-1 authoritative B2B potential-order ledger. All commercial WhatsApp intake remains visible and reconcilable until governed conversion or explicit closure.';
