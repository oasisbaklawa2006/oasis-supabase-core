-- WA-3: field-level, evidence-preserving WhatsApp order understanding.
-- Supabase CLI is not installed in this workspace; this canonical timestamp follows
-- the repository's monotonic WA migration lineage.

alter table public.whatsapp_sales_order_drafts alter column quantity drop default;

create or replace function public.create_whatsapp_sales_order_draft_from_operator(
  _source_message_id uuid,_resolved_sku text,_resolved_product_name text,_resolved_product_id uuid,
  _confidence_band text,_operator_decision text,_quantity numeric default null
) returns public.whatsapp_sales_order_drafts
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare msg public.whatsapp_inbound_messages; existing public.whatsapp_sales_order_drafts; inserted public.whatsapp_sales_order_drafts; draft_status text;
begin
  if auth.uid() is null or not public.has_whatsapp_permission('wa.draft.manage') then raise exception 'WA3_DRAFT_MANAGE_REQUIRED' using errcode='P0001'; end if;
  if _source_message_id is null then raise exception 'SOURCE_MESSAGE_REQUIRED'; end if;
  if nullif(btrim(_resolved_sku),'') is null then raise exception 'RESOLVED_SKU_REQUIRED'; end if;
  if _quantity is null then raise exception 'QUANTITY_UNRESOLVED' using errcode='P0001'; end if;
  if _quantity <= 0 then raise exception 'QUANTITY_MUST_BE_POSITIVE'; end if;
  if _confidence_band not in ('HIGH','MEDIUM','LOW') then raise exception 'INVALID_CONFIDENCE_BAND'; end if;
  if _operator_decision not in ('confirmed','alternative_selected') then raise exception 'INVALID_OPERATOR_DECISION'; end if;
  if _confidence_band='LOW' and _operator_decision<>'alternative_selected' then raise exception 'LOW_CONFIDENCE_REQUIRES_OPERATOR_SELECTION'; end if;
  select * into msg from public.whatsapp_inbound_messages where id=_source_message_id;
  if not found then raise exception 'SOURCE_MESSAGE_NOT_FOUND'; end if;
  select * into existing from public.whatsapp_sales_order_drafts where source_message_id=_source_message_id;
  if found then return existing; end if;
  draft_status:=case when _confidence_band='HIGH' then 'AI_DRAFT' else 'UNDER_REVIEW' end;
  insert into public.whatsapp_sales_order_drafts(source_message_id,sender_phone,customer_name,message_body,resolved_product_id,resolved_sku,resolved_product_name,confidence_band,operator_decision,status,quantity,created_by)
  values(msg.id,msg.sender_phone,msg.sender_name,msg.message_body,_resolved_product_id,btrim(_resolved_sku),nullif(btrim(_resolved_product_name),''),_confidence_band,_operator_decision,draft_status,_quantity,auth.uid()) returning * into inserted;
  insert into public.whatsapp_operator_decisions(source_message_id,action,sku,product_name,confidence_band,whatsapp_sales_order_draft_id,decided_by)
  values(msg.id,'confirm',inserted.resolved_sku,inserted.resolved_product_name,inserted.confidence_band,inserted.id,auth.uid());
  return inserted;
end $$;
revoke all on function public.create_whatsapp_sales_order_draft_from_operator(uuid,text,text,uuid,text,text,numeric) from public,anon;
grant execute on function public.create_whatsapp_sales_order_draft_from_operator(uuid,text,text,uuid,text,text,numeric) to authenticated,service_role;

alter table public.sales_order_drafts add column potential_order_id uuid references public.whatsapp_potential_orders(id) on delete restrict;
create unique index sales_order_drafts_potential_order_unique on public.sales_order_drafts(potential_order_id) where potential_order_id is not null;

create table public.whatsapp_order_field_resolutions(
  potential_order_id uuid not null references public.whatsapp_potential_orders(id) on delete restrict,
  field_key text not null check(field_key in('client_identity','product','quantity','unit_packaging','delivery_address','payment_terms','moq_carton')),
  resolution_state text not null default 'unresolved' check(resolution_state in('resolved','unresolved','ambiguous','conflicting','awaiting_clarification','operator_confirmed','not_applicable')),
  is_required boolean not null default true,
  resolved_value jsonb,
  resolved_evidence_id bigint,
  resolution_reason text,
  resolved_by uuid references public.users(id) on delete restrict,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(potential_order_id,field_key),
  constraint wa3_resolved_shape check(
    (resolution_state in('resolved','operator_confirmed') and resolved_value is not null and resolved_at is not null)
    or (resolution_state='not_applicable' and not is_required and resolution_reason is not null)
    or (resolution_state in('unresolved','ambiguous','conflicting','awaiting_clarification') and resolved_value is null)
  )
);

create table public.whatsapp_order_field_evidence(
  id bigint generated always as identity primary key,
  potential_order_id uuid not null references public.whatsapp_potential_orders(id) on delete restrict,
  field_key text not null check(field_key in('client_identity','product','quantity','unit_packaging','delivery_address','payment_terms','moq_carton')),
  source_message_id uuid not null references public.whatsapp_inbound_messages(id) on delete restrict,
  evidence_key text not null,
  candidate_value jsonb,
  extraction_state text not null check(extraction_state in('resolved','unresolved','ambiguous','conflicting','low_confidence','ai_failure','correction','operator_confirmation','historical_reference','not_applicable')),
  confidence numeric check(confidence is null or confidence between 0 and 1),
  source_excerpt text,
  metadata jsonb not null default '{}',
  recorded_by uuid references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(potential_order_id,field_key,evidence_key)
);

alter table public.whatsapp_order_field_resolutions add constraint wa3_resolution_evidence_fk
 foreign key(resolved_evidence_id) references public.whatsapp_order_field_evidence(id) on delete restrict;

create table public.whatsapp_order_clarification_tasks(
  id uuid primary key default gen_random_uuid(),
  potential_order_id uuid not null references public.whatsapp_potential_orders(id) on delete restrict,
  field_key text not null check(field_key in('client_identity','product','quantity','unit_packaging','delivery_address','payment_terms','moq_carton')),
  idempotency_key text not null,
  question text not null check(nullif(btrim(question),'') is not null),
  status text not null default 'OPEN' check(status in('OPEN','ANSWERED','SUPERSEDED','CANCELLED')),
  queue text not null default 'WA_COMMERCIAL_CLARIFICATION',
  owner_id uuid references public.users(id) on delete restrict,
  due_at timestamptz not null default(now()+interval '30 minutes'),
  answer_evidence_id bigint references public.whatsapp_order_field_evidence(id) on delete restrict,
  created_by uuid references public.users(id) on delete restrict,
  answered_by uuid references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  unique(potential_order_id,idempotency_key),
  constraint wa3_clarification_answer_shape check((status='ANSWERED' and answer_evidence_id is not null and answered_at is not null) or (status<>'ANSWERED' and answer_evidence_id is null and answered_at is null))
);

create index wa3_resolution_state_idx on public.whatsapp_order_field_resolutions(resolution_state,field_key);
create index wa3_evidence_order_idx on public.whatsapp_order_field_evidence(potential_order_id,field_key,created_at);
create index wa3_clarification_queue_idx on public.whatsapp_order_clarification_tasks(status,queue,due_at);

alter table public.whatsapp_order_field_resolutions enable row level security;
alter table public.whatsapp_order_field_evidence enable row level security;
alter table public.whatsapp_order_clarification_tasks enable row level security;
revoke all on public.whatsapp_order_field_resolutions,public.whatsapp_order_field_evidence,public.whatsapp_order_clarification_tasks from public,anon,authenticated;
grant select on public.whatsapp_order_field_resolutions,public.whatsapp_order_field_evidence,public.whatsapp_order_clarification_tasks to authenticated;
grant all on public.whatsapp_order_field_resolutions,public.whatsapp_order_field_evidence,public.whatsapp_order_clarification_tasks to service_role;

create policy wa3_resolution_read on public.whatsapp_order_field_resolutions for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));
create policy wa3_evidence_read on public.whatsapp_order_field_evidence for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));
create policy wa3_clarification_read on public.whatsapp_order_clarification_tasks for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));

create function public.wa3_append_only() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin raise exception 'WA3_APPEND_ONLY' using errcode='P0001'; end $$;
create trigger wa3_evidence_immutable before update or delete on public.whatsapp_order_field_evidence for each row execute function public.wa3_append_only();
create trigger wa3_clarification_delete_forbidden before delete on public.whatsapp_order_clarification_tasks for each row execute function public.wa3_append_only();

create function public.wa3_governed_resolution_write() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if current_setting('app.wa3_governed_mutation',true) is distinct from 'on' then raise exception 'WA3_GOVERNED_MUTATION_REQUIRED' using errcode='P0001'; end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
create trigger wa3_resolution_governed before insert or update or delete on public.whatsapp_order_field_resolutions for each row execute function public.wa3_governed_resolution_write();
create trigger wa3_clarification_governed before insert or update on public.whatsapp_order_clarification_tasks for each row execute function public.wa3_governed_resolution_write();

create function public.wa3_clarification_question(p_field_key text) returns text language sql immutable set search_path=public,pg_temp as $$
 select case p_field_key
  when 'client_identity' then 'Which customer account is this order for?'
  when 'product' then 'Which exact product or SKU do you want?'
  when 'quantity' then 'What quantity do you require?'
  when 'unit_packaging' then 'Is that quantity pieces, packs, boxes, or cartons?'
  when 'delivery_address' then 'Which delivery address should we use?'
  when 'payment_terms' then 'Which agreed payment terms apply to this order?'
  when 'moq_carton' then 'Please confirm the MOQ/carton quantity for this item.' end
$$;

create function public.record_whatsapp_order_field_evidence(
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
 if not exists(select 1 from public.whatsapp_inbound_messages m where m.id=p_source_message_id and (m.id=v_po.source_message_id or exists(select 1 from jsonb_array_elements(v_po.source_evidence) e where e->>'message_id'=m.id::text))) then raise exception 'WA3_SOURCE_NOT_LINKED'; end if;
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

create function public.answer_whatsapp_order_clarification(
 p_task_id uuid,p_source_message_id uuid,p_response_key text,p_candidate_value jsonb,p_source_excerpt text default null,p_metadata jsonb default '{}'
) returns public.whatsapp_order_field_resolutions
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_task public.whatsapp_order_clarification_tasks%rowtype; v_result public.whatsapp_order_field_resolutions%rowtype; v_evidence_id bigint;
begin
 if auth.uid() is null or not public.has_whatsapp_permission('wa.intake.triage') then raise exception 'WA3_TRIAGE_REQUIRED' using errcode='P0001'; end if;
 select * into v_task from public.whatsapp_order_clarification_tasks where id=p_task_id for update;
 if not found then raise exception 'WA3_TASK_NOT_FOUND'; end if;
 if v_task.status='ANSWERED' then select * into v_result from public.whatsapp_order_field_resolutions where potential_order_id=v_task.potential_order_id and field_key=v_task.field_key; return v_result; end if;
 if v_task.status<>'OPEN' then raise exception 'WA3_TASK_NOT_OPEN' using errcode='P0001'; end if;
 if p_candidate_value is null or p_candidate_value='null'::jsonb then raise exception 'WA3_ANSWER_VALUE_REQUIRED' using errcode='P0001'; end if;
 v_result:=public.record_whatsapp_order_field_evidence(v_task.potential_order_id,v_task.field_key,p_source_message_id,'clarification:'||p_response_key,p_candidate_value,'operator_confirmation',1,p_source_excerpt,p_metadata,true);
 select id into v_evidence_id from public.whatsapp_order_field_evidence where potential_order_id=v_task.potential_order_id and field_key=v_task.field_key and evidence_key='clarification:'||p_response_key;
 perform set_config('app.wa3_governed_mutation','on',true);
 update public.whatsapp_order_clarification_tasks set status='ANSWERED',answer_evidence_id=v_evidence_id,answered_by=auth.uid(),answered_at=now() where id=p_task_id;
 perform set_config('app.wa3_governed_mutation','off',true);
 return v_result;
exception when others then perform set_config('app.wa3_governed_mutation','off',true); raise;
end $$;

create function public.evaluate_whatsapp_order_readiness(p_potential_order_id uuid) returns jsonb
language sql stable security invoker set search_path=public,pg_temp as $$
 with required(field_key) as (values('client_identity'),('product'),('quantity'),('unit_packaging'),('delivery_address'),('payment_terms'),('moq_carton')),
 dimensions as (
  select r.field_key,coalesce(f.resolution_state,'unresolved') state,coalesce(f.is_required,true) is_required
  from required r left join public.whatsapp_order_field_resolutions f on f.potential_order_id=p_potential_order_id and f.field_key=r.field_key
 ) select jsonb_build_object('ready',bool_and((not is_required and state='not_applicable') or state in('resolved','operator_confirmed')),'dimensions',jsonb_agg(jsonb_build_object('field_key',field_key,'state',state,'required',is_required) order by field_key),'blocking_fields',coalesce(jsonb_agg(field_key order by field_key) filter(where not((not is_required and state='not_applicable') or state in('resolved','operator_confirmed'))),'[]'::jsonb)) from dimensions
$$;

create view public.whatsapp_order_readiness with(security_invoker=true) as
 select po.id potential_order_id,(r.readiness->>'ready')::boolean ready,r.readiness->'blocking_fields' blocking_fields,r.readiness->'dimensions' dimensions
 from public.whatsapp_potential_orders po
 cross join lateral(select public.evaluate_whatsapp_order_readiness(po.id) readiness) r;
revoke all on public.whatsapp_order_readiness from public,anon;
grant select on public.whatsapp_order_readiness to authenticated,service_role;

create function public.link_whatsapp_potential_order_draft(p_potential_order_id uuid,p_draft_id uuid) returns void
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
 if auth.uid() is null or not public.has_whatsapp_permission('wa.draft.manage') then raise exception 'WA3_DRAFT_MANAGE_REQUIRED' using errcode='P0001'; end if;
 -- Serialize all link attempts for a potential order, then lock the target draft.
 perform 1 from public.whatsapp_potential_orders where id=p_potential_order_id for update;
 if not found or not exists(select 1 from public.whatsapp_potential_orders where id=p_potential_order_id and disposition='ACTIVE_PENDING') then raise exception 'WA3_ACTIVE_POTENTIAL_ORDER_REQUIRED'; end if;
 perform 1 from public.sales_order_drafts where id=p_draft_id for update;
 if not found then raise exception 'WA3_DRAFT_NOT_FOUND'; end if;
 if exists(select 1 from public.sales_order_drafts where potential_order_id=p_potential_order_id and id<>p_draft_id) then raise exception 'WA3_DRAFT_LINK_CONFLICT' using errcode='P0001'; end if;
 if not exists(
  select 1 from public.sales_order_drafts d
  join public.whatsapp_messages wm on wm.packet_id=d.packet_id and wm.direction='inbound'
  join public.whatsapp_potential_orders po on po.id=p_potential_order_id
  where d.id=p_draft_id and wm.provider_message_id is not null
    and (wm.provider_message_id=po.provider_message_id or exists(
      select 1 from jsonb_array_elements(po.source_evidence) e where e->>'provider_message_id'=wm.provider_message_id
    ))
 ) then raise exception 'WA3_DRAFT_SOURCE_LINEAGE_MISMATCH' using errcode='P0001'; end if;
 update public.sales_order_drafts set potential_order_id=p_potential_order_id,updated_by=auth.uid(),updated_at=now() where id=p_draft_id and potential_order_id is null;
 if not found and not exists(select 1 from public.sales_order_drafts where id=p_draft_id and potential_order_id=p_potential_order_id) then raise exception 'WA3_DRAFT_LINK_CONFLICT'; end if;
end $$;

create function public.wa3_assert_draft_ready_for_promotion() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_readiness jsonb;
begin
 if new.status='APPROVED_FOR_SO' and (tg_op='INSERT' or old.status is distinct from new.status or old.promoted_order_id is distinct from new.promoted_order_id) then
  -- potential_order_id is the Core authority discriminator. Generic drafts keep
  -- their canonical readiness path; linked WhatsApp drafts additionally require WA-3 readiness.
  if new.potential_order_id is null then return new; end if;
  v_readiness:=public.evaluate_whatsapp_order_readiness(new.potential_order_id);
  if not coalesce((v_readiness->>'ready')::boolean,false) then raise exception 'WA3_COMMERCIAL_DIMENSIONS_UNRESOLVED: %',v_readiness->'blocking_fields' using errcode='P0001'; end if;
 end if;
 return new;
end $$;
create trigger wa3_draft_promotion_readiness before insert or update on public.sales_order_drafts for each row execute function public.wa3_assert_draft_ready_for_promotion();

-- Close the WA-2 insert-time promotion gap without changing its role model.
create or replace function public.wa2_guard_sales_order_draft_write() returns trigger
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
 if auth.role()='service_role' then return new; end if;
 if auth.uid() is null or not public.has_whatsapp_permission('wa.draft.manage') then raise exception 'WA2_DRAFT_MANAGE_REQUIRED' using errcode='P0001'; end if;
 if tg_table_name='sales_order_drafts'
   and (new.status='APPROVED_FOR_SO' or new.promoted_order_id is not null)
   and (tg_op='INSERT' or old.status is distinct from new.status or old.promoted_order_id is distinct from new.promoted_order_id)
   and not public.has_whatsapp_permission('wa.draft.promote') then raise exception 'WA2_DRAFT_PROMOTE_REQUIRED' using errcode='P0001'; end if;
 if tg_table_name='sales_order_draft_audit_log' and new.action='APPROVE'
   and not public.has_whatsapp_permission('wa.draft.promote') then raise exception 'WA2_DRAFT_PROMOTE_REQUIRED' using errcode='P0001'; end if;
 return new;
end $$;

create function public.get_whatsapp_clarification_summary() returns table(unresolved bigint,conflicting bigint,open_questions bigint,overdue bigint)
language sql stable security invoker set search_path=public,pg_temp as $$
 select
  (select count(*) from public.whatsapp_order_field_resolutions where resolution_state in('unresolved','ambiguous','conflicting','awaiting_clarification')),
  (select count(*) from public.whatsapp_order_field_resolutions where resolution_state='conflicting'),
  (select count(*) from public.whatsapp_order_clarification_tasks where status='OPEN'),
  (select count(*) from public.whatsapp_order_clarification_tasks where status='OPEN' and due_at<now())
$$;

revoke all on function public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean),public.answer_whatsapp_order_clarification(uuid,uuid,text,jsonb,text,jsonb),public.evaluate_whatsapp_order_readiness(uuid),public.link_whatsapp_potential_order_draft(uuid,uuid),public.get_whatsapp_clarification_summary() from public,anon;
grant execute on function public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean) to authenticated,service_role;
grant execute on function public.answer_whatsapp_order_clarification(uuid,uuid,text,jsonb,text,jsonb),public.evaluate_whatsapp_order_readiness(uuid),public.link_whatsapp_potential_order_draft(uuid,uuid) to authenticated,service_role;
grant execute on function public.get_whatsapp_clarification_summary() to authenticated,service_role;
revoke all on function public.wa3_append_only(),public.wa3_governed_resolution_write(),public.wa3_assert_draft_ready_for_promotion() from public,anon,authenticated;
revoke all on function public.wa2_guard_sales_order_draft_write() from public,anon,authenticated;

comment on table public.whatsapp_order_field_evidence is 'WA-3 immutable candidate and correction evidence. Contradictions append; they never overwrite source interpretation.';
comment on function public.evaluate_whatsapp_order_readiness(uuid) is 'Core-authoritative deterministic commercial readiness. Every required dimension must be resolved or operator-confirmed.';
