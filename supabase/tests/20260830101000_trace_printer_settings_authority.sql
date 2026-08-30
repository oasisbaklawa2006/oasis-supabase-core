-- Contract for 20260830101000_trace_printer_settings_authority.sql
begin;

select plan(21);

select has_table('public', 'ols_printers', 'Core owns the Trace printer table');
select has_column('public', 'ols_printers', 'settings', 'ols_printers.settings exists');
select col_type_is('public', 'ols_printers', 'settings', 'jsonb', 'printer settings are jsonb');
select has_function(
  'public', 'trace_save_printer_settings_v1', array['uuid', 'jsonb'],
  'governed printer settings mutation RPC exists'
);

select ok(
  (select a.attnotnull
     from pg_attribute a
    where a.attrelid = 'public.ols_printers'::regclass
      and a.attname = 'settings'
      and not a.attisdropped),
  'printer settings cannot be null'
);

select ok(
  (select pg_get_expr(d.adbin, d.adrelid) = '''{}''::jsonb'
     from pg_attribute a
     join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
    where a.attrelid = 'public.ols_printers'::regclass
      and a.attname = 'settings'
      and not a.attisdropped),
  'printer settings default to an empty JSON object'
);

-- Capture the generated fixture id from RETURNING; printer names are not unique.
create temp table trace_printer_default_fixture (id uuid primary key) on commit drop;
with inserted as (
  insert into public.ols_printers (name, model, command_lang)
  values ('pgTAP Trace Default Printer', 'contract', 'TSPL')
  returning id
)
insert into trace_printer_default_fixture (id)
select id from inserted;

select is(
  (select p.settings
     from public.ols_printers p
     join trace_printer_default_fixture f on f.id = p.id),
  '{}'::jsonb,
  'new printers receive an empty settings object by default'
);

select ok(
  not exists (
    select 1 from pg_policy
     where polrelid = 'public.ols_printers'::regclass
       and polname in ('ols_auth_read', 'ols_auth_write', 'ols_auth_update')
  ),
  'legacy permissive printer policies are removed'
);

select ok(
  exists (
    select 1 from pg_policy
     where polrelid = 'public.ols_printers'::regclass
       and polname = 'trace_internal_read'
       and polcmd = 'r'
  ),
  'internal Trace read policy is present'
);

select is(
  has_function_privilege('authenticated', 'public.trace_save_printer_settings_v1(uuid,jsonb)', 'EXECUTE'),
  true,
  'authenticated operators can invoke the governed RPC'
);
select is(
  has_function_privilege('anon', 'public.trace_save_printer_settings_v1(uuid,jsonb)', 'EXECUTE'),
  false,
  'anonymous callers cannot invoke the governed RPC'
);
select is(
  has_function_privilege('service_role', 'public.trace_save_printer_settings_v1(uuid,jsonb)', 'EXECUTE'),
  false,
  'service_role is not exposed to an RPC that requires a real auth.uid()'
);
select is(
  has_table_privilege('authenticated', 'public.ols_printers', 'UPDATE'),
  false,
  'authenticated callers cannot bypass the RPC with direct printer updates'
);
select is(
  has_table_privilege('authenticated', 'public.ols_printers', 'INSERT'),
  false,
  'authenticated callers cannot bypass governance with direct printer inserts'
);

-- One real internal role and one deliberately non-internal TV role.
insert into auth.users (id, email) values
  ('14500000-0000-0000-0000-000000000001', 'trace-printer-admin@pgtap.invalid'),
  ('14500000-0000-0000-0000-000000000002', 'trace-printer-tv@pgtap.invalid');
insert into public.users (id, email, role) values
  ('14500000-0000-0000-0000-000000000001', 'trace-printer-admin@pgtap.invalid', 'super_admin'),
  ('14500000-0000-0000-0000-000000000002', 'trace-printer-tv@pgtap.invalid', 'tv_ready');

insert into public.ols_printers (
  id, name, model, command_lang, settings, updated_at
) values (
  '14500000-0000-0000-0000-000000000010',
  'pgTAP Trace Authority Printer',
  'contract',
  'TSPL',
  '{"legacyKey":"preserve","darkness":6}'::jsonb,
  '2000-01-01 00:00:00+00'::timestamptz
);

-- No authenticated identity: fail closed.
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  $$ select public.trace_save_printer_settings_v1('14500000-0000-0000-0000-000000000010', '{"darkness":8}'::jsonb) $$,
  42501, 'TRACE_PRINTER_SETTINGS_FORBIDDEN',
  'printer settings RPC rejects an unauthenticated caller'
);

-- Authenticated but non-internal identity: still fail closed.
select set_config('request.jwt.claim.sub', '14500000-0000-0000-0000-000000000002', true);
select throws_ok(
  $$ select public.trace_save_printer_settings_v1('14500000-0000-0000-0000-000000000010', '{"darkness":8}'::jsonb) $$,
  42501, 'TRACE_PRINTER_SETTINGS_FORBIDDEN',
  'printer settings RPC rejects a non-internal authenticated caller'
);

-- Internal operator: validate inputs before mutation.
select set_config('request.jwt.claim.sub', '14500000-0000-0000-0000-000000000001', true);
select throws_ok(
  $$ select public.trace_save_printer_settings_v1(null, '{}'::jsonb) $$,
  22023, 'TRACE_PRINTER_ID_REQUIRED',
  'printer settings RPC rejects a null printer id'
);
select throws_ok(
  $$ select public.trace_save_printer_settings_v1('14500000-0000-0000-0000-000000000010', '[]'::jsonb) $$,
  22023, 'TRACE_PRINTER_SETTINGS_OBJECT_REQUIRED',
  'printer settings RPC rejects a non-object settings payload'
);

select lives_ok(
  $$ select public.trace_save_printer_settings_v1(
       '14500000-0000-0000-0000-000000000010',
       '{"darkness":9,"host":"10.0.0.50"}'::jsonb
     ) $$,
  'internal operator can save printer settings through the governed RPC'
);

select is(
  (select settings from public.ols_printers
    where id = '14500000-0000-0000-0000-000000000010'),
  '{"legacyKey":"preserve","darkness":9,"host":"10.0.0.50"}'::jsonb,
  'RPC merges changed settings without erasing unknown existing keys'
);

select ok(
  (select updated_at > '2000-01-01 00:00:00+00'::timestamptz
     from public.ols_printers
    where id = '14500000-0000-0000-0000-000000000010'),
  'successful governed update refreshes updated_at'
);

select * from finish();
rollback;
