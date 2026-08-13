-- WA-6: fail-closed commercial disclosure authority for governed WhatsApp replies.
-- Additive/roll-forward migration; no existing evidence or outbound history is removed.

insert into public.access_permissions(permission_key,description,risk_level,is_active,requires_step_up)
values('wa.disclosure.authorize','Authorize recipient commercial disclosure scope','high_risk',true,true)
on conflict(permission_key) do update set description=excluded.description,risk_level=excluded.risk_level,is_active=true,requires_step_up=true;
insert into public.role_permission_grants(role_key,permission_key,effect)
values('super_admin','wa.disclosure.authorize','allow'),('admin','wa.disclosure.authorize','allow')
on conflict(role_key,permission_key) do update set effect=excluded.effect;

create table public.whatsapp_sender_commercial_authorizations(
 id uuid primary key default gen_random_uuid(),
 contact_id uuid not null references public.whatsapp_contacts(id) on delete restrict,
 company_id uuid not null references public.companies(id) on delete restrict,
 disclosure_scope text[] not null check(disclosure_scope <@ array['customer_pricing','moq_carton','payment_terms','delivery_address','previous_orders','account_balance','draft_order','sales_order']),
 identity_evidence jsonb not null check(jsonb_typeof(identity_evidence)='object' and identity_evidence<>'{}'::jsonb),
 status text not null default 'ACTIVE' check(status in('ACTIVE','REVOKED','EXPIRED')),
 authorized_by uuid not null references public.users(id) on delete restrict,
 authorized_at timestamptz not null default now(),
 valid_until timestamptz not null,
 revoked_by uuid references public.users(id) on delete restrict,
 revoked_at timestamptz,
 created_at timestamptz not null default now(),
 check(valid_until>authorized_at),
 check((status='REVOKED')=(revoked_by is not null and revoked_at is not null))
);
create unique index wa6_active_sender_authorization on public.whatsapp_sender_commercial_authorizations(contact_id,company_id) where status='ACTIVE';
alter table public.whatsapp_sender_commercial_authorizations enable row level security;
revoke all on public.whatsapp_sender_commercial_authorizations from public,anon,authenticated;
grant select on public.whatsapp_sender_commercial_authorizations to authenticated;
create policy wa6_authorization_read on public.whatsapp_sender_commercial_authorizations for select to authenticated using(public.has_whatsapp_permission('wa.intake.read'));

create function public.authorize_whatsapp_commercial_disclosure(p_contact_id uuid,p_company_id uuid,p_disclosure_scope text[],p_identity_evidence jsonb,p_valid_until timestamptz) returns public.whatsapp_sender_commercial_authorizations
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_result public.whatsapp_sender_commercial_authorizations%rowtype;
begin
 if auth.uid() is null or not public.has_whatsapp_permission('wa.disclosure.authorize') then raise exception 'WA6_DISCLOSURE_AUTHORITY_REQUIRED' using errcode='P0001'; end if;
 if p_valid_until<=now() or p_valid_until>now()+interval '1 year' then raise exception 'WA6_INVALID_AUTHORIZATION_WINDOW'; end if;
 if coalesce(cardinality(p_disclosure_scope),0)=0 then raise exception 'WA6_DISCLOSURE_SCOPE_REQUIRED'; end if;
 perform set_config('app.wa6_authorization_mutation','on',true);
 update public.whatsapp_sender_commercial_authorizations set status='REVOKED',revoked_by=auth.uid(),revoked_at=now() where contact_id=p_contact_id and company_id=p_company_id and status='ACTIVE';
 insert into public.whatsapp_sender_commercial_authorizations(contact_id,company_id,disclosure_scope,identity_evidence,authorized_by,valid_until)
 values(p_contact_id,p_company_id,p_disclosure_scope,p_identity_evidence,auth.uid(),p_valid_until) returning * into v_result;
 perform set_config('app.wa6_authorization_mutation','off',true);
 return v_result;
exception when others then perform set_config('app.wa6_authorization_mutation','off',true); raise;
end $$;

create function public.wa6_infer_commercial_disclosure(p_message text) returns text[]
language sql immutable strict set search_path=pg_catalog as $$
 select array_remove(array[
  case when p_message ~* '(₹|(^|[^a-z])rs\.?([^a-z]|$)|(^|[^a-z])price([^a-z]|$)|(^|[^a-z])rate([^a-z]|$))' then 'customer_pricing' end,
  case when p_message ~* '((^|[^a-z])moq([^a-z]|$)|minimum order|carton constraint)' then 'moq_carton' end,
  case when p_message ~* '(payment terms|credit days|advance payment)' then 'payment_terms' end,
  case when p_message ~* '(delivery address|ship to|deliver to)' then 'delivery_address' end,
  case when p_message ~* '(previous order|last order|last time)' then 'previous_orders' end,
  case when p_message ~* '(account balance|outstanding balance|amount due)' then 'account_balance' end,
  case when p_message ~* '(draft order|draft number)' then 'draft_order' end,
  case when p_message ~* '(sales order|(^|[^a-z])so[- #])' then 'sales_order' end
 ],null)::text[]
$$;

create function public.wa6_guard_operator_reply_disclosure() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_inferred text[]; v_required text[]; v_company_id uuid;
begin
 v_inferred:=public.wa6_infer_commercial_disclosure(new.message_body);
 select array_agg(distinct scope order by scope) into v_required from unnest(coalesce(new.disclosure_scope,'{}')||coalesce(v_inferred,'{}')) scope;
 new.disclosure_scope:=coalesce(v_required,'{}');
 if cardinality(new.disclosure_scope)=0 then return new; end if;
 if new.potential_order_id is null then raise exception 'WA6_COMMERCIAL_DISCLOSURE_REQUIRES_GOVERNED_ORDER'; end if;
 select case when r.resolution_state in('resolved','operator_confirmed') and r.resolved_value->>'company_id' ~ '^[0-9a-fA-F-]{36}$' then (r.resolved_value->>'company_id')::uuid end
 into v_company_id from public.whatsapp_order_field_resolutions r where r.potential_order_id=new.potential_order_id and r.field_key='client_identity';
 if v_company_id is null then raise exception 'WA6_VERIFIED_CUSTOMER_REQUIRED'; end if;
 if not exists(select 1 from public.whatsapp_sender_commercial_authorizations a where a.contact_id=new.contact_id and a.company_id=v_company_id and a.status='ACTIVE' and a.valid_until>now() and new.disclosure_scope<@a.disclosure_scope) then
  raise exception 'WA6_DISCLOSURE_SCOPE_NOT_AUTHORIZED';
 end if;
 return new;
end $$;
create trigger wa6_operator_reply_disclosure before insert on public.whatsapp_operator_reply_outbox for each row execute function public.wa6_guard_operator_reply_disclosure();

create trigger wa6_sender_authorization_immutable before update or delete on public.whatsapp_sender_commercial_authorizations for each row
when (coalesce(current_setting('app.wa6_authorization_mutation',true),'off')<>'on') execute function public.wa1_audit_immutable();

create or replace function public.has_whatsapp_permission(p_permission_key text) returns boolean
language sql stable security definer set search_path=public,auth,pg_temp as $$
 select auth.uid() is not null
   and exists(select 1 from public.users u where u.id=auth.uid() and coalesce(u.is_active,true) and u.deleted_at is null)
   and p_permission_key=any(array['wa.intake.read','wa.intake.triage','wa.intake.assign','wa.intake.close','wa.draft.manage','wa.draft.promote','wa.reply.send','wa.disclosure.authorize'])
   and public.has_app_permission(auth.uid(),p_permission_key,null,null)
$$;
create or replace function public.get_my_whatsapp_permissions() returns text[]
language sql stable security definer set search_path=public,auth,pg_temp as $$
 select coalesce(array_agg(p order by p),'{}'::text[]) from unnest(array[
  'wa.intake.read','wa.intake.triage','wa.intake.assign','wa.intake.close','wa.draft.manage','wa.draft.promote','wa.reply.send','wa.disclosure.authorize'
 ]) p where public.has_whatsapp_permission(p)
$$;

revoke all on function public.authorize_whatsapp_commercial_disclosure(uuid,uuid,text[],jsonb,timestamptz) from public,anon,authenticated;
grant execute on function public.authorize_whatsapp_commercial_disclosure(uuid,uuid,text[],jsonb,timestamptz) to authenticated,service_role;
revoke all on function public.wa6_infer_commercial_disclosure(text),public.wa6_guard_operator_reply_disclosure() from public,anon,authenticated;

comment on table public.whatsapp_sender_commercial_authorizations is 'WA-6 time-bounded, identity-evidenced authority for customer-specific WhatsApp disclosure.';
