-- WA-2: Core-authoritative WhatsApp identity and least-privilege RBAC.

insert into public.roles(role_key,role_name,is_active) values
 ('super_admin','Super Admin',true),('admin','Admin',true),('support_executive','Support Executive',true)
on conflict(role_key) do update set is_active=true;

-- Backfill the canonical role map for active legacy staff before role labels stop
-- being accepted as WhatsApp authorization evidence.
insert into public.user_role_map(user_id,role_id)
select u.id,r.id from public.users u join public.roles r on r.role_key=lower(btrim(u.role))
where lower(btrim(u.role)) in('super_admin','admin','support_executive')
  and coalesce(u.is_active,true) and u.deleted_at is null
on conflict(user_id,role_id) do nothing;

insert into public.access_permissions(permission_key,description,risk_level,is_active,requires_step_up)
values
 ('wa.intake.read','Read WhatsApp commercial intake, evidence and reconciliation','standard',true,false),
 ('wa.intake.triage','Interpret, clarify and move active WhatsApp commercial intake','sensitive',true,false),
 ('wa.intake.assign','Assign WhatsApp commercial intake ownership and queues','sensitive',true,false),
 ('wa.intake.close','Explicitly close WhatsApp commercial intake','high_risk',true,true),
 ('wa.draft.manage','Create and edit governed WhatsApp sales-order drafts','sensitive',true,false),
 ('wa.draft.promote','Promote an approved WhatsApp draft through Core authority','high_risk',true,true)
on conflict(permission_key) do update set description=excluded.description,risk_level=excluded.risk_level,
 is_active=excluded.is_active,requires_step_up=excluded.requires_step_up,updated_at=now();

insert into public.role_permission_grants(role_key,permission_key,effect)
select role_key,permission_key,'allow' from (values
 ('super_admin','wa.intake.read'),('super_admin','wa.intake.triage'),('super_admin','wa.intake.assign'),
 ('super_admin','wa.intake.close'),('super_admin','wa.draft.manage'),('super_admin','wa.draft.promote'),
 ('admin','wa.intake.read'),('admin','wa.intake.triage'),('admin','wa.intake.assign'),
 ('admin','wa.intake.close'),('admin','wa.draft.manage'),('admin','wa.draft.promote'),
 ('support_executive','wa.intake.read'),('support_executive','wa.intake.triage'),
 ('support_executive','wa.intake.assign'),('support_executive','wa.draft.manage')
) as grants(role_key,permission_key)
on conflict(role_key,permission_key) do update set effect=excluded.effect;

create or replace function public.has_whatsapp_permission(p_permission_key text) returns boolean
language sql stable security definer set search_path=public,auth,pg_temp as $$
 select auth.uid() is not null
   and exists(select 1 from public.users u where u.id=auth.uid() and coalesce(u.is_active,true) and u.deleted_at is null)
   and p_permission_key=any(array['wa.intake.read','wa.intake.triage','wa.intake.assign','wa.intake.close','wa.draft.manage','wa.draft.promote'])
   and public.has_app_permission(auth.uid(),p_permission_key,null,null)
$$;

create or replace function public.get_my_whatsapp_permissions() returns text[]
language sql stable security definer set search_path=public,auth,pg_temp as $$
 select coalesce(array_agg(p order by p),'{}'::text[]) from unnest(array[
  'wa.intake.read','wa.intake.triage','wa.intake.assign','wa.intake.close','wa.draft.manage','wa.draft.promote'
 ]) p where public.has_whatsapp_permission(p)
$$;

create or replace function public.is_whatsapp_inbox_reader(_user_id uuid) returns boolean
language sql stable security definer set search_path=public,auth,pg_temp as $$
 select _user_id is not distinct from auth.uid() and public.has_whatsapp_permission('wa.intake.read')
$$;
comment on function public.is_whatsapp_inbox_reader(uuid) is 'WA-2 compatibility helper. Core wa.intake.read permission is authoritative; caller-supplied identities cannot be evaluated.';

revoke all on function public.has_whatsapp_permission(text),public.get_my_whatsapp_permissions(),public.is_whatsapp_inbox_reader(uuid) from public,anon;
grant execute on function public.has_whatsapp_permission(text),public.get_my_whatsapp_permissions(),public.is_whatsapp_inbox_reader(uuid) to authenticated,service_role;

drop policy if exists whatsapp_potential_orders_reader on public.whatsapp_potential_orders;
create policy whatsapp_potential_orders_reader on public.whatsapp_potential_orders for select to authenticated
 using(public.has_whatsapp_permission('wa.intake.read'));
drop policy if exists whatsapp_potential_order_audit_reader on public.whatsapp_potential_order_audit_log;
create policy whatsapp_potential_order_audit_reader on public.whatsapp_potential_order_audit_log for select to authenticated
 using(public.has_whatsapp_permission('wa.intake.read'));

drop policy if exists sales_order_drafts_inbox_reader_select on public.sales_order_drafts;
create policy sales_order_drafts_inbox_reader_select on public.sales_order_drafts for select to authenticated
 using(public.has_whatsapp_permission('wa.intake.read'));
drop policy if exists sales_order_drafts_inbox_reader_insert on public.sales_order_drafts;
create policy sales_order_drafts_inbox_reader_insert on public.sales_order_drafts for insert to authenticated
 with check(public.has_whatsapp_permission('wa.draft.manage'));
drop policy if exists sales_order_drafts_inbox_reader_update on public.sales_order_drafts;
create policy sales_order_drafts_inbox_reader_update on public.sales_order_drafts for update to authenticated
 using(public.has_whatsapp_permission('wa.draft.manage')) with check(public.has_whatsapp_permission('wa.draft.manage'));

drop policy if exists sales_order_draft_lines_inbox_reader_select on public.sales_order_draft_lines;
create policy sales_order_draft_lines_inbox_reader_select on public.sales_order_draft_lines for select to authenticated
 using(public.has_whatsapp_permission('wa.intake.read') and exists(select 1 from public.sales_order_drafts d where d.id=draft_id));
drop policy if exists sales_order_draft_lines_inbox_reader_insert on public.sales_order_draft_lines;
create policy sales_order_draft_lines_inbox_reader_insert on public.sales_order_draft_lines for insert to authenticated
 with check(public.has_whatsapp_permission('wa.draft.manage') and exists(select 1 from public.sales_order_drafts d where d.id=draft_id));
drop policy if exists sales_order_draft_lines_inbox_reader_update on public.sales_order_draft_lines;
create policy sales_order_draft_lines_inbox_reader_update on public.sales_order_draft_lines for update to authenticated
 using(public.has_whatsapp_permission('wa.draft.manage') and exists(select 1 from public.sales_order_drafts d where d.id=draft_id))
 with check(public.has_whatsapp_permission('wa.draft.manage') and exists(select 1 from public.sales_order_drafts d where d.id=draft_id));

drop policy if exists sales_order_draft_audit_inbox_reader_select on public.sales_order_draft_audit_log;
create policy sales_order_draft_audit_inbox_reader_select on public.sales_order_draft_audit_log for select to authenticated
 using(public.has_whatsapp_permission('wa.intake.read'));
drop policy if exists sales_order_draft_audit_inbox_reader_insert on public.sales_order_draft_audit_log;
create policy sales_order_draft_audit_inbox_reader_insert on public.sales_order_draft_audit_log for insert to authenticated
 with check(public.has_whatsapp_permission('wa.draft.manage') and actor_id=auth.uid());

create or replace function public.wa2_guard_sales_order_draft_write() returns trigger
language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
 if auth.role()='service_role' then return new; end if;
 if auth.uid() is null or not public.has_whatsapp_permission('wa.draft.manage') then raise exception 'WA2_DRAFT_MANAGE_REQUIRED' using errcode='P0001'; end if;
 if tg_table_name='sales_order_drafts' and tg_op='UPDATE'
   and (new.status='APPROVED_FOR_SO' or new.promoted_order_id is not null)
   and (old.status is distinct from new.status or old.promoted_order_id is distinct from new.promoted_order_id)
   and not public.has_whatsapp_permission('wa.draft.promote') then raise exception 'WA2_DRAFT_PROMOTE_REQUIRED' using errcode='P0001'; end if;
 if tg_table_name='sales_order_draft_audit_log' and new.action='APPROVE'
   and not public.has_whatsapp_permission('wa.draft.promote') then raise exception 'WA2_DRAFT_PROMOTE_REQUIRED' using errcode='P0001'; end if;
 return new;
end $$;

create trigger wa2_sales_order_drafts_write_guard before insert or update on public.sales_order_drafts
 for each row execute function public.wa2_guard_sales_order_draft_write();
create trigger wa2_sales_order_draft_lines_write_guard before insert or update on public.sales_order_draft_lines
 for each row execute function public.wa2_guard_sales_order_draft_write();
create trigger wa2_sales_order_draft_audit_write_guard before insert on public.sales_order_draft_audit_log
 for each row execute function public.wa2_guard_sales_order_draft_write();
create trigger wa2_sales_order_draft_audit_immutable before update or delete on public.sales_order_draft_audit_log
 for each row execute function public.wa1_audit_immutable();

revoke all on function public.wa2_guard_sales_order_draft_write() from public,anon,authenticated;

create or replace function public.transition_whatsapp_potential_order(
 p_potential_order_id uuid,p_to_state text,p_owner_id uuid,p_queue text,p_next_action text,p_due_at timestamptz,
 p_sales_order_draft_id uuid default null,p_sales_order_id uuid default null,p_close_reason text default null,p_expected_updated_at timestamptz default null,p_evidence jsonb default '{}'
) returns public.whatsapp_potential_orders
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.whatsapp_potential_orders%rowtype; v_new public.whatsapp_potential_orders%rowtype; v_disp text; v_allowed boolean:=false;
begin
 if auth.uid() is null or not public.has_whatsapp_permission('wa.intake.triage') then raise exception 'WA2_TRIAGE_REQUIRED' using errcode='P0001'; end if;
 select * into v_old from public.whatsapp_potential_orders where id=p_potential_order_id for update;
 if not found then raise exception 'POTENTIAL_ORDER_NOT_FOUND'; end if;
 if p_expected_updated_at is not null and v_old.updated_at is distinct from p_expected_updated_at then raise exception 'STALE_TRANSITION'; end if;
 if v_old.disposition<>'ACTIVE_PENDING' then if v_old.state=p_to_state then return v_old; end if; raise exception 'TERMINAL_STATE_IMMUTABLE'; end if;
 if (p_owner_id is distinct from v_old.owner_id
     or (nullif(btrim(p_queue),'') is not null and nullif(btrim(p_queue),'') is distinct from v_old.queue))
   and not public.has_whatsapp_permission('wa.intake.assign') then raise exception 'WA2_ASSIGN_REQUIRED' using errcode='P0001'; end if;
 if p_to_state='EXPLICITLY_CLOSED' and not public.has_whatsapp_permission('wa.intake.close') then raise exception 'WA2_CLOSE_REQUIRED' using errcode='P0001'; end if;
 if p_to_state='CONVERTED' and not public.has_whatsapp_permission('wa.draft.promote') then raise exception 'WA2_PROMOTE_REQUIRED' using errcode='P0001'; end if;
 v_allowed:=p_to_state in ('UNASSIGNED','FAILED_INTERPRETATION','AWAITING_CLARIFICATION','AGEING','AT_RISK','ESCALATED','EXPLICITLY_CLOSED')
  or(p_to_state='CONVERTED' and p_sales_order_draft_id is not null and p_sales_order_id is not null and exists(select 1 from public.sales_order_drafts d where d.id=p_sales_order_draft_id and d.promoted_order_id=p_sales_order_id and d.status='APPROVED_FOR_SO'));
 if not v_allowed then raise exception 'INVALID_WA1_TRANSITION'; end if;
 if p_to_state not in ('UNASSIGNED','FAILED_INTERPRETATION') and p_owner_id is null then raise exception 'OWNER_REQUIRED'; end if;
 if p_to_state='EXPLICITLY_CLOSED' and nullif(btrim(p_close_reason),'') is null then raise exception 'CLOSE_REASON_REQUIRED'; end if;
 v_disp:=case when p_to_state='CONVERTED' then 'CONVERTED' when p_to_state='EXPLICITLY_CLOSED' then 'EXPLICITLY_CLOSED' else 'ACTIVE_PENDING' end;
 perform set_config('app.wa1_governed_mutation','on',true);
 update public.whatsapp_potential_orders set state=p_to_state,disposition=v_disp,owner_id=p_owner_id,queue=coalesce(nullif(btrim(p_queue),''),queue),next_action=coalesce(nullif(btrim(p_next_action),''),next_action),next_action_due_at=coalesce(p_due_at,next_action_due_at),sla_state=case when p_to_state='AGEING' then 'AGEING' when p_to_state='AT_RISK' then 'AT_RISK' when p_to_state='ESCALATED' then 'BREACHED' else sla_state end,sales_order_draft_id=case when p_to_state='CONVERTED' then p_sales_order_draft_id else sales_order_draft_id end,sales_order_id=case when p_to_state='CONVERTED' then p_sales_order_id else null end,closed_reason=case when p_to_state='EXPLICITLY_CLOSED' then btrim(p_close_reason) else null end,closed_by=case when p_to_state='EXPLICITLY_CLOSED' then auth.uid() else null end,closed_at=case when p_to_state='EXPLICITLY_CLOSED' then now() else null end,updated_at=now() where id=p_potential_order_id returning * into v_new;
 insert into public.whatsapp_potential_order_audit_log(potential_order_id,action,from_state,to_state,actor_id,evidence) values(v_new.id,'STATE_TRANSITION',v_old.state,v_new.state,auth.uid(),coalesce(p_evidence,'{}')||jsonb_build_object('wa2_permissions',public.get_my_whatsapp_permissions()));
 perform set_config('app.wa1_governed_mutation','off',true);
 return v_new;
exception when others then perform set_config('app.wa1_governed_mutation','off',true); raise;
end $$;

revoke all on function public.transition_whatsapp_potential_order(uuid,text,uuid,text,text,timestamptz,uuid,uuid,text,timestamptz,jsonb) from public,anon;
grant execute on function public.transition_whatsapp_potential_order(uuid,text,uuid,text,text,timestamptz,uuid,uuid,text,timestamptz,jsonb) to authenticated,service_role;

comment on function public.has_whatsapp_permission(text) is 'WA-2 Core authority: active-user, deny-overrides, step-up-aware WhatsApp capability decision.';
