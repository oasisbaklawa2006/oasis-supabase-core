-- Repair the canonical auth.users -> public.users onboarding handoff.
--
-- Production evidence on 2026-09-10 showed on_auth_user_created firing
-- public.handle_new_user(), but the function attempted role = NULL while
-- public.users.role is NOT NULL. The exception was swallowed, leaving a valid
-- GoTrue/Auth identity with no governed public.users identity. Central then
-- could not carry that prospect into the B2B access-request flow.
--
-- Ownership boundary:
--   * ordinary GoTrue end-user identities without a phone are provisioned here
--     as non-privileged PENDING identities;
--   * phone-bound identities are owned by the canonical MSG91 Edge handshake,
--     which creates/binds public.users only after provider verification;
--   * direct SQL/system fixtures without provider metadata are explicitly
--     governed by their owning migrations/tests and are not auto-provisioned.
--
-- This prevents the auth trigger from racing MSG91 v73's canonical phone
-- identity insert or changing governed system-principal fixture semantics.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  v_provider text := lower(coalesce(new.raw_app_meta_data ->> 'provider', ''));
begin
  -- Direct SQL/system principals do not carry GoTrue provider metadata. Their
  -- owning governed routines must create public.users explicitly.
  if v_provider = '' then
    return new;
  end if;

  -- MSG91 is the canonical mobile authority. Its Edge function verifies the
  -- provider access token first and only then creates/binds public.users.
  if nullif(btrim(coalesce(new.phone, '')), '') is not null then
    return new;
  end if;

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

-- Production already has this trigger from legacy history, but canonical clean
-- replay did not. Recreate it idempotently so production and Core replay agree.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- Trigger functions are invoked by PostgreSQL; callers do not need direct
-- EXECUTE. Keep this server-owned and fail closed if governed provisioning
-- itself fails.
revoke all on function public.handle_new_user() from public;
revoke all on function public.handle_new_user() from anon;
revoke all on function public.handle_new_user() from authenticated;

comment on function public.handle_new_user() is
  'Canonical GoTrue onboarding trigger: provisions non-phone end-user identities as non-privileged PENDING public.users rows; MSG91 phone identities and direct system fixtures remain owned by their explicit governed paths.';