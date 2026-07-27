-- Point 25 clean-replay repair: is_internal_staff(uuid) existed in production
-- before Core migration ownership. Preserve the production implementation when
-- present and create a compatibility implementation only for clean replay.

do $migration$
begin
  if to_regprocedure('public.is_internal_staff(uuid)') is null then
    execute $function$
      create function public.is_internal_staff(_user_id uuid)
      returns boolean
      language sql
      stable
      security definer
      set search_path = public, pg_temp
      as $body$
        select exists (
          select 1
          from public.user_role_map urm
          join public.roles r on r.id = urm.role_id
          where urm.user_id = _user_id
            and coalesce(r.is_active, true)
            and upper(r.role_key) = any (array[
              'SUPER_ADMIN', 'ADMIN', 'OWNER', 'FINANCE_HEAD', 'FINANCE_EXEC',
              'OPERATIONS_MANAGER', 'OPERATIONS_EXEC', 'PRODUCTION_MANAGER',
              'ASSEMBLY_MANAGER', 'PACKING_SUPERVISOR', 'DISPATCH_HEAD',
              'DISPATCH_MANAGER', 'SUPPORT_EXECUTIVE', 'SALES_EXECUTIVE'
            ])
        )
      $body$
    $function$;
  end if;
end
$migration$;

revoke all on function public.is_internal_staff(uuid) from public, anon, authenticated;
grant execute on function public.is_internal_staff(uuid) to authenticated, service_role;

comment on function public.is_internal_staff(uuid) is
  'Legacy internal-staff compatibility helper retained for deterministic Core migration replay.';
