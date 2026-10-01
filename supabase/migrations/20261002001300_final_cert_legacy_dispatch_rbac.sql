-- Final certification repair: remove authenticated full-write authority from legacy dispatches.
-- Preserve buyer-own read and internal read compatibility; mutations belong to Dispatch/Operations/Admin.

begin;

drop policy if exists "Allow authenticated full access on dispatches" on public.dispatches;

create policy "Internal staff read legacy dispatches"
on public.dispatches
for select to authenticated
using (public.is_internal_staff(auth.uid()));

create policy "Dispatch authority insert legacy dispatches"
on public.dispatches
for insert to authenticated
with check (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in (
    'DISPATCH_MANAGER','DISPATCH_HEAD','DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'
  )
);

create policy "Dispatch authority update legacy dispatches"
on public.dispatches
for update to authenticated
using (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in (
    'DISPATCH_MANAGER','DISPATCH_HEAD','DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'
  )
)
with check (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in (
    'DISPATCH_MANAGER','DISPATCH_HEAD','DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'
  )
);

create policy "Dispatch authority delete legacy dispatches"
on public.dispatches
for delete to authenticated
using (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in (
    'DISPATCH_MANAGER','DISPATCH_HEAD','DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'
  )
);

commit;
