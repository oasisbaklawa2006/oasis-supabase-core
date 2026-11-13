-- MSG91 phone-identity authority: close the direct public-profile write channel.
-- A provider-verified phone must never be established by self-writable fields
-- on public.users. This migration does not rewrite any existing identity/data.
-- Existing clients that need to change identity phone numbers must use a
-- separately reviewed verified-phone claim route, never an unrestricted UPDATE.

-- Direct REST users can currently UPDATE every public.users column via a
-- table-wide grant. Revoke that grant before installing column-scoped updates.
-- Keep all existing non-phone UPDATE column rights for authenticated users;
-- never grant any additional right to anon. Service/owner grants stay intact.
revoke update on table public.users from public, anon, authenticated;

do $msg91_phone_column_grants$
declare
  v_safe_columns text;
begin
  select string_agg(format('%I', a.attname), ', ' order by a.attnum)
    into v_safe_columns
  from pg_attribute a
  where a.attrelid = 'public.users'::regclass
    and a.attnum > 0
    and not a.attisdropped
    and a.attgenerated = ''
    and a.attidentity = ''
    and a.attname not in ('phone', 'mobile_number', 'secondary_phones');

  if v_safe_columns is null then
    raise exception 'MSG91_PROFILE_COLUMN_GRANT_PRECONDITION_FAILED' using errcode = 'P0001';
  end if;
  execute format('grant update (%s) on table public.users to authenticated', v_safe_columns);
end;
$msg91_phone_column_grants$;

-- Defence in depth: fail closed even if an overly broad table UPDATE grant
-- is accidentally reintroduced later. An auth client must never turn a
-- user-controlled profile contact into a provider-verified login identifier.
-- SECURITY INVOKER preserves the actual database role of the statement:
-- direct API calls run as authenticated/anon; a governed SECURITY DEFINER
-- routine with separately verified proof runs under its trusted owner.
create or replace function public.msg91_deny_untrusted_profile_phone_write_v1()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, public
as $msg91_phone_guard$
begin
  if current_user in ('authenticated', 'anon')
     and (new.phone is distinct from old.phone
       or new.mobile_number is distinct from old.mobile_number
       or new.secondary_phones is distinct from old.secondary_phones) then
    raise exception 'MSG91_VERIFIED_PHONE_WRITE_REQUIRES_GOVERNED_AUTHORITY'
      using errcode = '42501';
  end if;
  return new;
end;
$msg91_phone_guard$;

revoke all on function public.msg91_deny_untrusted_profile_phone_write_v1()
  from public, anon, authenticated;

drop trigger if exists trg_msg91_protect_profile_phone_v1 on public.users;
create trigger trg_msg91_protect_profile_phone_v1
before update of phone, mobile_number, secondary_phones on public.users
for each row
execute function public.msg91_deny_untrusted_profile_phone_write_v1();

comment on function public.msg91_deny_untrusted_profile_phone_write_v1() is
  'Defence-in-depth: reject unauthorised direct public profile phone changes. Only independently governed verified-phone binding may change MSG91 login identities.';
