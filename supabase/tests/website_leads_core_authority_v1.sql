-- Contract tests for migration 20261124000000_website_leads_core_authority_v1.
-- Verifies the RLS lock, the privilege matrix, the retention guard, synced-only purge and updated_at.
begin;

select plan(15);

select ok(
  to_regclass('public.website_leads') is not null,
  'website_leads table exists'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.website_leads'::regclass),
  'row level security is enabled on website_leads'
);

select ok(
  not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'website_leads'),
  'website_leads has no RLS policies'
);

select ok(
  not has_table_privilege('anon', 'public.website_leads', 'SELECT')
  and not has_table_privilege('anon', 'public.website_leads', 'INSERT')
  and not has_table_privilege('anon', 'public.website_leads', 'UPDATE')
  and not has_table_privilege('anon', 'public.website_leads', 'DELETE'),
  'anon has no table privileges on website_leads'
);

select ok(
  not has_table_privilege('authenticated', 'public.website_leads', 'SELECT')
  and not has_table_privilege('authenticated', 'public.website_leads', 'INSERT')
  and not has_table_privilege('authenticated', 'public.website_leads', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.website_leads', 'DELETE'),
  'authenticated has no table privileges on website_leads'
);

select ok(
  has_table_privilege('service_role', 'public.website_leads', 'SELECT')
  and has_table_privilege('service_role', 'public.website_leads', 'INSERT')
  and has_table_privilege('service_role', 'public.website_leads', 'UPDATE'),
  'service_role has read and write privileges on website_leads'
);

select ok(
  not has_function_privilege('anon', 'public.purge_synced_website_leads_v1(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.purge_synced_website_leads_v1(integer)', 'EXECUTE'),
  'anon and authenticated cannot execute the retention helper'
);

select ok(
  has_function_privilege('service_role', 'public.purge_synced_website_leads_v1(integer)', 'EXECUTE'),
  'service_role can execute the retention helper'
);

select throws_ok(
  $$ select public.purge_synced_website_leads_v1(29) $$,
  'P0001',
  'WEBSITE_LEADS_RETENTION_TOO_SHORT',
  'retention below 30 days is rejected'
);

select throws_ok(
  $$ insert into public.website_leads (kind, dedupe_key, email, source) values ('bogus', 'k-bad-kind', 'a@example.invalid', 'test') $$,
  '23514',
  null,
  'unknown lead kind is rejected by check constraint'
);

select throws_ok(
  $$ insert into public.website_leads (kind, dedupe_key, source) values ('contact', 'k-no-contact', 'test') $$,
  '23514',
  null,
  'lead without email or phone is rejected'
);

-- Fixtures: one old synced lead (purge target), one old pending lead and one recent synced lead (both kept).
insert into public.website_leads (id, kind, dedupe_key, email, source, sync_state, synced_at, created_at)
values
  ('00000000-0000-0000-0000-00000000a001', 'contact', 'k-old-synced', 'old@example.invalid', 'test', 'synced', now() - interval '400 days', now() - interval '400 days'),
  ('00000000-0000-0000-0000-00000000a002', 'contact', 'k-old-pending', 'pending@example.invalid', 'test', 'pending_sync', null, now() - interval '400 days'),
  ('00000000-0000-0000-0000-00000000a003', 'contact', 'k-recent-synced', 'recent@example.invalid', 'test', 'synced', now() - interval '1 day', now() - interval '1 day');

select is(
  public.purge_synced_website_leads_v1(30),
  1,
  'purge removes only the old synced lead'
);

select ok(
  exists (select 1 from public.website_leads where id = '00000000-0000-0000-0000-00000000a002')
  and exists (select 1 from public.website_leads where id = '00000000-0000-0000-0000-00000000a003')
  and not exists (select 1 from public.website_leads where id = '00000000-0000-0000-0000-00000000a001'),
  'pending and recent leads are kept, old synced lead is gone'
);

select ok(
  (select updated_at from public.website_leads where id = '00000000-0000-0000-0000-00000000a003')
    >= (select created_at from public.website_leads where id = '00000000-0000-0000-0000-00000000a003'),
  'updated_at is populated on insert'
);

update public.website_leads set message = 'touched' where id = '00000000-0000-0000-0000-00000000a003';

select ok(
  (select updated_at from public.website_leads where id = '00000000-0000-0000-0000-00000000a003')
    > now() - interval '1 minute',
  'updated_at trigger refreshes on update'
);

select * from finish();

rollback;
