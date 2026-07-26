-- Point 25 clean-replay compatibility: production already has get_user_role(uuid).
-- Preserve the production definition when present; create a Core-compatible fallback
-- only for clean-room replay where legacy public.users is intentionally absent.

do $$
begin
  if to_regprocedure('public.get_user_role(uuid)') is null then
    execute $function$
      create function public.get_user_role(_user_id uuid)
      returns text
      language sql
      stable
      security definer
      set search_path = public
      as $body$
        select upper(r.role_key)
        from public.user_role_map urm
        join public.roles r on r.id = urm.role_id
        where urm.user_id = _user_id
          and coalesce(r.is_active, true)
        order by
          case upper(r.role_key)
            when 'SUPER_ADMIN' then 1
            when 'ADMIN' then 2
            when 'FINANCE_HEAD' then 3
            when 'OPERATIONS_MANAGER' then 4
            when 'PRODUCTION_MANAGER' then 5
            when 'FINANCE_EXEC' then 6
            when 'DISPATCH_MANAGER' then 7
            when 'STORE_INCHARGE' then 8
            when 'SUPPORT_EXECUTIVE' then 9
            when 'SALES_EXECUTIVE' then 10
            else 99
          end
        limit 1
      $body$
    $function$;
  end if;
end
$$;

revoke all on function public.get_user_role(uuid) from public, anon, authenticated;
grant execute on function public.get_user_role(uuid) to authenticated, service_role;

comment on function public.get_user_role(uuid) is
  'Returns the highest-priority active legacy role for compatibility with historical policies.';
