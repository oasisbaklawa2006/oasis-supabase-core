-- WA-100 P0 / Core #538: legacy WhatsApp OTPs must not be readable through
-- the general authenticated app-settings API. Forward-only, no data mutation.
-- Preserve existing non-OTP settings contract for Central staff/admin pages.
-- SERVICE_ROLE retains access for the legacy function pending its protected retirement.
--
-- Production audit 2026-11-16: app_settings holds eight wa_otp_ rows, all expired.
-- This migration intentionally neither reads their plaintext values nor deletes them.
--
-- Do NOT change other security policies or broaden role permissions.
begin;

do $wa100_validate$
begin
  if to_regclass('public.app_settings') is null then
    raise exception 'WA100_P0_APP_SETTINGS_TABLE_MISSING';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'public' and tablename = 'app_settings'
      and policyname = 'Authenticated can read app_settings'
      and cmd = 'SELECT' and 'authenticated' = any(roles)
  ) then
    raise exception 'WA100_P0_EXPECTED_READ_POLICY_MISSING_OR_CHANGED';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'public' and tablename = 'app_settings'
      and policyname = 'Admins manage app_settings'
      and cmd = 'ALL' and 'authenticated' = any(roles)
  ) then
    raise exception 'WA100_P0_EXPECTED_ADMIN_POLICY_MISSING_OR_CHANGED';
  end if;
end;
$wa100_validate$;

-- Restrict existing broad read policy by protected key prefix.
-- Do not use LIKE with unescaped underscores; left(..., 7) is exact.
alter policy "Authenticated can read app_settings"
  on public.app_settings
  to authenticated
  using (left(setting_key, 7) <> 'wa_otp_');

-- Existing authenticated admin policy is additive with SELECT policies.
-- It must also exclude OTP rows to avoid a permissive-policy bypass.
-- Preserve the existing non-OTP admin predicate for other settings.
alter policy "Admins manage app_settings"
  on public.app_settings
  to authenticated
  using (
    left(setting_key, 7) <> 'wa_otp_'
    and exists (
      select 1 from public.users u
      where u.id = auth.uid()
        and u.role = any(array['admin'::text, 'super_admin'::text])
    )
  )
  with check (
    left(setting_key, 7) <> 'wa_otp_'
    and exists (
      select 1 from public.users u
      where u.id = auth.uid()
        and u.role = any(array['admin'::text, 'super_admin'::text])
    )
  );

commit;
