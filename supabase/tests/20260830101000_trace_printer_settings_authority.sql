-- Contract for 20260830101000_trace_printer_settings_authority.sql
begin;

select plan(8);

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

select is(
  (select settings from public.ols_printers
    where id = (
      select id from public.ols_printers order by created_at, id limit 1
    )),
  coalesce((select settings from public.ols_printers order by created_at, id limit 1), '{}'::jsonb),
  'existing printer settings remain valid jsonb'
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

select * from finish();
rollback;
