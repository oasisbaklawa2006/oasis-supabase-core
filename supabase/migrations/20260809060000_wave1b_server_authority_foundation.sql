-- Wave 1B: governed server-authority foundation.
-- Canonical reconstruction from staging objects; safe to replay after Core main.

alter table public.orders add column if not exists finance_verified_by uuid;
alter table public.orders add column if not exists finance_verified_at timestamptz;
alter table public.orders add column if not exists payment_rejection_reason text;

create or replace function public.assert_order_transition_role(p_action text)
returns void language plpgsql stable set search_path = public, pg_temp as $$
declare v_role text := upper(coalesce(public.get_user_role(auth.uid()), ''));
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode='P0001'; end if;
  if p_action in ('release_manufacturing','finance_review','record_full_payment') and v_role not in ('FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: finance authority required' using errcode='P0001';
  elsif p_action='confirm_awaiting_advance' and v_role not in ('SALES_EXECUTIVE','SALES_EXEC','OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: sales or operations authority required' using errcode='P0001';
  elsif p_action='mark_packed_ready' and v_role not in ('PACKING_SUPERVISOR','OPERATIONS_MANAGER','ASSEMBLY_SUPERVISOR','ASSEMBLY_HEAD','DISPATCH_HEAD','DISPATCH_MANAGER','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: packing or operations authority required' using errcode='P0001';
  elsif p_action='clear_dispatch' and v_role not in ('FINANCE_HEAD','FINANCE_EXEC','DISPATCH_HEAD','DISPATCH_MANAGER','DISPATCH_INCHARGE','OPERATIONS_MANAGER','PACKING_SUPERVISOR','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: dispatch clearance authority required' using errcode='P0001';
  elsif p_action='gate_release' and v_role not in ('SECURITY_CONTROL','GATE_SECURITY','DISPATCH_HEAD','DISPATCH_MANAGER','DISPATCH_INCHARGE','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: gate authority required' using errcode='P0001';
  elsif p_action not in ('release_manufacturing','finance_review','record_full_payment','confirm_awaiting_advance','mark_packed_ready','clear_dispatch','gate_release') then
    raise exception 'INVALID_ACTION: %',p_action using errcode='P0001';
  end if;
end $$;

create or replace function public.is_advance_verification_path_cleared(p_payment_status text)
returns boolean language sql immutable set search_path=pg_catalog,public as $$
  select lower(btrim(coalesce(p_payment_status,''))) in ('paid','short_term_credit','verified_advance','advance_paid','on_credit')
$$;

create or replace function public.protect_order_authority_fields()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if current_user='postgres' then return new; end if;
  if tg_op='INSERT' then
    if lower(coalesce(new.status,'')) not in ('draft','submitted')
       or coalesce(new.payment_cleared,false)
       or coalesce(new.advance_paid,0)<>0
       or new.finance_verified_by is not null
       or new.finance_verified_at is not null then
      raise exception 'ORDER_AUTHORITY_REQUIRED_ON_INSERT' using errcode='P0001';
    end if;
    return new;
  end if;
  if new.status is distinct from old.status then raise exception 'ORDER_STATUS_AUTHORITY_REQUIRED' using errcode='P0001'; end if;
  if new.payment_status is distinct from old.payment_status or new.payment_cleared is distinct from old.payment_cleared
     or new.advance_paid is distinct from old.advance_paid or new.advance_required is distinct from old.advance_required
     or new.sales_order_value is distinct from old.sales_order_value or new.document_stage is distinct from old.document_stage
     or new.finance_verified_by is distinct from old.finance_verified_by or new.finance_verified_at is distinct from old.finance_verified_at
     or new.payment_rejection_reason is distinct from old.payment_rejection_reason then
    raise exception 'ORDER_FINANCE_AUTHORITY_REQUIRED' using errcode='P0001';
  end if;
  return new;
end $$;
drop trigger if exists trg_protect_order_authority_fields on public.orders;
create trigger trg_protect_order_authority_fields before insert or update on public.orders for each row execute function public.protect_order_authority_fields();

create or replace function public.prevent_audit_log_mutation() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin raise exception 'audit_logs are append-only (%)',tg_op using errcode='P0001'; end $$;
drop trigger if exists trg_audit_logs_no_update on public.audit_logs;
drop trigger if exists trg_audit_logs_no_delete on public.audit_logs;
create trigger trg_audit_logs_no_update before update on public.audit_logs for each row execute function public.prevent_audit_log_mutation();
create trigger trg_audit_logs_no_delete before delete on public.audit_logs for each row execute function public.prevent_audit_log_mutation();

drop policy if exists "Admins can view and edit all orders" on public.orders;
drop policy if exists finance_exec_update_payment_fields on public.orders;
drop policy if exists "Staff can insert all orders" on public.orders;
drop policy if exists "Staff can update all orders" on public.orders;
drop policy if exists "Staff can delete all orders" on public.orders;
drop policy if exists "Admins read all orders" on public.orders;
create policy "Admins read all orders" on public.orders for select to authenticated
using (lower(coalesce((select u.role from public.users u where u.id=auth.uid() limit 1),'')) in ('admin','super_admin'));
drop policy if exists "Staff append audit_logs as self" on public.audit_logs;
create policy "Staff append audit_logs as self" on public.audit_logs for insert to authenticated
with check (public.is_internal_staff(auth.uid()) and actor_id=auth.uid());

revoke all on function public.assert_order_transition_role(text) from public,anon,authenticated;
revoke all on function public.protect_order_authority_fields() from public,anon,authenticated;
revoke all on function public.prevent_audit_log_mutation() from public,anon,authenticated;
grant execute on function public.assert_order_transition_role(text) to authenticated,service_role;
