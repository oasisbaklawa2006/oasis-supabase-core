-- WA-100 P0 / #538: pgTAP regression for legacy OTP secrecy.
-- Runs only on protected preview replay. Entire test transaction rolls back.
begin;
select plan(11);

select has_table('public', 'app_settings', 'app_settings exists');
select has_policy('public', 'app_settings', 'Authenticated can read app_settings');
select has_policy('public', 'app_settings', 'Admins manage app_settings');

select ok(
  exists(select 1 from pg_catalog.pg_policies
    where schemaname='public' and tablename='app_settings'
      and policyname='Authenticated can read app_settings'
      and position('wa_otp_' in coalesce(qual,'')) > 0),
  'authenticated SELECT policy explicitly excludes OTP key prefix');
select ok(
  exists(select 1 from pg_catalog.pg_policies
    where schemaname='public' and tablename='app_settings'
      and policyname='Admins manage app_settings'
      and position('wa_otp_' in coalesce(qual,'')) > 0
      and position('wa_otp_' in coalesce(with_check,'')) > 0),
  'authenticated admin ALL policy cannot bypass OTP select/write restriction');

insert into public.app_settings(setting_key, setting_value)
values
 ('wa_otp_wa100_p0_rls_fixture', '{"code":"TEST_ONLY_DO_NOT_DELIVER","expiresAt":0}'::jsonb),
 ('wa100_p0_nonotp_fixture', '{"visible":true}'::jsonb);

select is((select count(*)::int from public.app_settings where setting_key='wa_otp_wa100_p0_rls_fixture'), 1,
  'setup: OTP fixture exists before role switch');

set local role authenticated;
select is((select count(*)::int from public.app_settings where setting_key='wa_otp_wa100_p0_rls_fixture'), 0,
  'ordinary authenticated caller cannot select OTP code row');
select is((select count(*)::int from public.app_settings where setting_key='wa100_p0_nonotp_fixture'), 1,
  'ordinary authenticated caller retains non-secret settings read');
select is((select count(*)::int from public.app_settings where left(setting_key,7)='wa_otp_'), 0,
  'all OTP rows are invisible to authenticated caller');
reset role;

set local role anon;
select is((select count(*)::int from public.app_settings where setting_key='wa_otp_wa100_p0_rls_fixture'), 0,
  'anonymous caller cannot select OTP row');
reset role;

set local role service_role;
select is((select count(*)::int from public.app_settings where setting_key='wa_otp_wa100_p0_rls_fixture'), 1,
  'service_role can continue backend expiry/transition operations on OTP row');
reset role;

select * from finish();
rollback;
