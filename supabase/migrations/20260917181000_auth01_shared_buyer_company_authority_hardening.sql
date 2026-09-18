-- AUTH-01 shared Buyer/customer authority hardening.
--
-- auth_buyer_company_id() is used by authenticated customer financial,
-- complaint, ledger, payment and RLS surfaces. Historically it was only an
-- identity -> company lookup and therefore did not enforce role, approval,
-- staff exclusion, identity activity, company activity, or frozen state.
--
-- Harden the existing primitive in place so all current dependents inherit
-- the same fail-closed company authority without rewriting every caller.
-- Preserve legitimate legacy customer users explicitly:
-- customer_user/customer_admin/buyer/b2b_customer, active + non-deleted,
-- on active/not-frozen companies.
-- Modern Buyer profiles require approved Buyer role and active/not-frozen
-- company. Internal staff is never resolved through this Buyer/customer
-- helper; callers that intentionally support staff already carry an explicit
-- is_internal_staff() or service_role bypass.

create or replace function public.auth_buyer_company_id()
returns uuid
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'auth'
as $function$
  select case
    when auth.uid() is null then null::uuid
    when coalesce(public.is_internal_staff(auth.uid()), false) then null::uuid
    else coalesce(
      (
        select u.company_id
        from public.users u
        join public.companies c on c.id = u.company_id
        where u.id = auth.uid()
          and u.company_id is not null
          and lower(coalesce(u.role, '')) in (
            'customer_user',
            'customer_admin',
            'buyer',
            'b2b_customer'
          )
          and coalesce(u.is_active, true) is true
          and u.deleted_at is null
          and lower(coalesce(c.status, '')) in ('active', 'approved')
          and coalesce(c.is_frozen, false) is false
        limit 1
      ),
      (
        select p.company_id
        from public.profiles p
        join public.companies c on c.id = p.company_id
        where p.id = auth.uid()
          and p.company_id is not null
          and p.is_approved is true
          and lower(coalesce(p.status, '')) = 'approved'
          and lower(coalesce(p.role, '')) in ('b2b_buyer', 'buyer')
          and not public.is_staff_role(p.role)
          and lower(coalesce(c.status, '')) in ('active', 'approved')
          and coalesce(c.is_frozen, false) is false
        limit 1
      )
    )
  end;
$function$;

revoke all on function public.auth_buyer_company_id() from public, anon;
grant execute on function public.auth_buyer_company_id() to authenticated, service_role;

comment on function public.auth_buyer_company_id() is
  'Governed Buyer/customer company authority. Resolves only active eligible legacy customer users or approved non-staff Buyer profiles on active, non-frozen companies; internal staff must use explicit staff authority paths.';
