-- Contract assertions for 20260723150000_rls_metadata_hardening_and_step_up.sql
-- Run after migrations against a disposable or controlled database.

begin;

do $$
begin
  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename in ('orders', 'whatsapp_messages')
      and policyname in (
        'operations_view_in_production_orders',
        'whatsapp_messages_finance_ops'
      )
      and coalesce(qual, '') ilike '%user_metadata%'
  ) then
    raise exception 'unsafe user_metadata authorization remains in protected RLS policies';
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'access_permissions'
      and column_name = 'requires_step_up'
      and data_type = 'boolean'
  ) then
    raise exception 'access_permissions.requires_step_up is missing';
  end if;

  if not exists (
    select 1
    from public.access_permissions
    where permission_key = 'rbac.manage'
      and requires_step_up
      and is_active
  ) then
    raise exception 'rbac.manage is not configured for step-up authentication';
  end if;
end $$;

do $$
begin
  if to_regprocedure('public.has_step_up_auth()') is null then
    raise exception 'has_step_up_auth() is missing';
  end if;

  if to_regprocedure('public.has_app_permission(uuid,text,uuid,uuid)') is null then
    raise exception 'has_app_permission(uuid,text,uuid,uuid) is missing';
  end if;
end $$;

do $$
declare
  fn regprocedure;
begin
  foreach fn in array array[
    'public.has_active_company_membership(uuid,uuid)'::regprocedure,
    'public.has_app_permission(uuid,text,uuid,uuid)'::regprocedure
  ] loop
    if has_function_privilege('anon', fn, 'EXECUTE') then
      raise exception 'anon retains EXECUTE on %', fn;
    end if;
  end loop;
end $$;

rollback;
