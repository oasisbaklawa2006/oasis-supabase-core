-- Repair the canonical auth.users -> public.users onboarding handoff.
--
-- Production evidence on 2026-09-10 showed on_auth_user_created firing
-- public.handle_new_user(), but the function attempted role = NULL while
-- public.users.role is NOT NULL. The exception was swallowed, leaving a valid
-- auth.users row with no governed public.users identity. Central then could not
-- carry a newly created prospect into the B2B access-request flow.
--
-- New Auth identities must enter the governed identity layer as PENDING only.
-- Staff or buyer authority is granted later by the existing governed flows.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $function$
begin
  insert into public.users (
    id,
    email,
    role,
    is_active,
    invite_status
  )
  values (
    new.id,
    new.email,
    'PENDING',
    true,
    'pending'
  )
  on conflict (id) do nothing;

  return new;
end;
$function$;

-- Trigger functions are invoked by PostgreSQL; callers do not need direct
-- EXECUTE. Keep this server-owned and fail closed if provisioning itself fails.
revoke all on function public.handle_new_user() from public;
revoke all on function public.handle_new_user() from anon;
revoke all on function public.handle_new_user() from authenticated;

comment on function public.handle_new_user() is
  'Canonical auth.users onboarding trigger: creates one non-privileged PENDING public.users identity. Never grants staff or buyer approval authority.';
